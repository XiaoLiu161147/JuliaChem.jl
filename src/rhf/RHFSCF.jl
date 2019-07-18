Base.include(@__MODULE__,"../math/math.jl")

Base.include(@__MODULE__,"ReadIn.jl")

using BasisStructs

using MPI
using Base.Threads
#using Distributed
using LinearAlgebra
using HDF5

function rhf_energy(basis::Basis, molecule::Dict{String,Any},
  scf_flags::Dict{String,Any})

  if (scf_flags["prec"] == "Float64")
    return rhf_kernel(basis,molecule,scf_flags,oneunit(Float64))
  elseif (scf_flags["prec"] == "Float32")
    return rhf_kernel(basis,molecule,scf_flags,oneunit(Float32))
  end
end


"""
	 rhf_kernel(FLAGS::RHF_Flags, basis::Basis, read_in::Dict{String,Any},
       type::T)
Summary
======
Perform the core RHF SCF algorithm.

Arguments
======
FLAGS = Input flags

basis = Generated basis set

read_in = file required to read in from input file

type = Precision of variables in calculation
"""
function rhf_kernel(basis::Basis, molecule::Dict{String,Any},
  scf_flags::Dict{String,Any}, type::T) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD
  calculation_status::Dict{String,Any} = Dict([])

  #== read variables from input if needed ==#
  E_nuc::T = molecule["enuc"]

  S::Array{T,2} = read_in_oei(molecule["ovr"], basis.norb)
  H::Array{T,2} = read_in_oei(molecule["hcore"], basis.norb)

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("Overlap matrix:")
    display(S)
    println("")

    println("Hamiltonian matrix:")
    display(H)
    println("")
  end

  #== build the orthogonalization matrix ==#
  S_evec::Array{T,2} = eigvecs(LinearAlgebra.Hermitian(S))

  S_eval_diag::Array{T,1} = eigvals(LinearAlgebra.Hermitian(S))

  S_eval::Array{T,2} = zeros(basis.norb,basis.norb)
  for i::Int64 in 1:basis.norb
    S_eval[i,i] = S_eval_diag[i]
  end

  ortho::Array{T,2} = S_evec*
    (LinearAlgebra.Diagonal(S_eval)^-0.5)*transpose(S_evec)

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("Ortho matrix:")
    display(ortho)
    println("")
  end

  #== build the initial matrices ==#
  F::Array{T,2} = H
  D = Matrix{T}(undef,basis.norb,basis.norb)
  C = Matrix{T}(undef,basis.norb,basis.norb)

  if (MPI.Comm_rank(comm) == 0)
    println("----------------------------------------          ")
	println("       Starting RHF iterations...                 ")
	println("----------------------------------------          ")
	println(" ")
	println("Iter      Energy                   ΔE                   Drms")
  end

  F, D, C, E_elec = iteration(F, D, H, ortho, basis, scf_flags)

  E::T = E_elec + E_nuc
  E_old::T = E

  if (MPI.Comm_rank(comm) == 0)
    println(0,"     ", E)
  end

  #=============================#
  #== start scf cycles: #7-10 ==#
  #=============================#
  converged::Bool = false
  iter::Int64 = 1

  c = h5open("tei.h5", "r") do tei
    while(!converged)
      #== build fock matrix ==#
	  F_temp = twoei(F, D, tei, H, basis)

	  F = MPI.Allreduce(F_temp,MPI.SUM,comm)
	  MPI.Barrier(comm)

	  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
        println("Skeleton Fock matrix:")
        display(F)
        println("")
	  end

	  F += deepcopy(H)

      if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
        println("Total Fock matrix:")
        display(F)
        println("")
      end

      #== obtain new F,D,C matrices ==#
      D_old::Array{T,2} = deepcopy(D)

	  F, D, C, E_elec = iteration(F, D, H, ortho, basis, scf_flags)

      #== check for convergence ==#
      ΔD::Array{T,2} = D - D_old
	  D_rms::T = √(∑(ΔD,ΔD))

	  E = E_elec+E_nuc
	  ΔE::T = E - E_old

	  if (MPI.Comm_rank(comm) == 0)
	    println(iter,"     ", E,"     ", ΔE,"     ", D_rms)
	  end

	  converged = (abs(ΔE) <= scf_flags["dele"]) && (D_rms <= scf_flags["rmsd"])
	  iter += 1
      if (iter > scf_flags["niter"]) break end

      #== if not converged, replace old D and E values for next iteration ==#
      D_old = deepcopy(D)
      E_old = E
    end
  end

  if (iter > scf_flags["niter"])
    if (MPI.Comm_rank(comm) == 0)
	    println(" ")
      println("----------------------------------------")
      println(" The SCF calculation did not converge.  ")
      println("      Restart data is being output.     ")
      println("----------------------------------------")
      println(" ")
    end

    iter_limit = scf_flags["niter"]
    calculation_fail::Dict{String,Any} = Dict(
    "success" => false,
    "error" => Dict(
      "error_type" => "convergence_error",
      "error_message" => " SCF calculation did not converge within $iter_limit
        iterations. "
      )
    )

    merge!(calculation_status, calculation_fail)

  else
    if (MPI.Comm_rank(comm) == 0)
      println(" ")
      println("----------------------------------------")
      println("   The SCF calculation has converged!   ")
      println("----------------------------------------")
      println("Total SCF Energy: ",E," h")
      println(" ")

      calculation_success::Dict{String,Any} = Dict(
      "return_result" => E,
      "success" => true,
      "properties" => Dict(
        "return_energy" => E,
        "nuclear_repulsion_energy" => E_nuc,
        "scf_iterations" => iter,
        "scf_total_energy" => E
        )
      )

      merge!(calculation_status, calculation_success)
    end

	#if (FLAGS.SCF.debug == true)
    #  close(json_debug)
    #end
  end

  return (F, D, C, E, calculation_status)
end

#=
"""
	 iteration(F::Array{T,2}, D::Array{T,2}, H::Array{T,2}, ortho::Array{T,2})
Summary
======
Perform single SCF iteration.

Arguments
======
F = Current iteration's Fock Matrix

D = Current iteration's Density Matrix

H = One-electron Hamiltonian Matrix

ortho = Symmetric Orthogonalization Matrix
"""
=#
function iteration(F_μν::Array{T,2}, D::Array{T,2}, H::Array{T,2},
  ortho::Array{T,2}, basis::Basis, scf_flags) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD

  #== obtain new orbital coefficients ==#
  F = transpose(ortho)*F_μν*ortho

  F_eval::Array{T,1} = eigvals(LinearAlgebra.Hermitian(F))

  F_evec::Array{T,2} = eigvecs(LinearAlgebra.Hermitian(F))
  F_evec = F_evec[:,sortperm(F_eval)] #sort evecs according to sorted evals

  C::Array{T,2} = ortho*F_evec

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New orbitals:")
    display(C)
    println("")
  end

  #== build new density matrix ==#
  nocc::Int64 = basis.nels/2
  norb = basis.norb

  for i::Int64 in 1:basis.norb, j::Int64 in 1:basis.norb
    D[i,j] = ∑(C[i,1:nocc],C[j,1:nocc])
    #D[i,j] = ∑(C[1:nocc,i],C[1:nocc,j])
    D[i,j] *= 2
  end

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New density matrix:")
    display(D)
    println("")
  end

  #== compute new SCF energy ==#
  EHF1::T = ∑(D,F_μν)
  EHF2::T = ∑(D,H)
  E_elec::T = (EHF1 + EHF2)/2

  if (scf_flags["debug"] == true && MPI.Comm_rank(comm) == 0)
    println("New energy:")
    println("$EHF1, $EHF2")
    println("")
  end

  return (F, D, C, E_elec)
end
#=
"""
	 index(a::Int64,b::Int64)
Summary
======
Triangular indexing determination.

Arguments
======
a = row index

b = column index
"""
=#
@inline function index(a::Int64,b::Int64)
  index::Int64 = (a*(a-1)) >> 1 #bitwise divide by 2
  index += b
  return index
end

#=
"""
	 twoei(F::Array{T}, D::Array{T}, tei::Array{T}, H::Array{T})
Summary
======
Perform Fock build step.

Arguments
======
F = Current iteration's Fock Matrix

D = Current iteration's Density Matrix

tei = Two-electron integral array

H = One-electron Hamiltonian Matrix
"""
=#

function twoei(F::Array{T,2}, D::Array{T,2}, tei::HDF5File,
  H::Array{T,2}, basis::Basis) where {T<:AbstractFloat}

  comm=MPI.COMM_WORLD
  nsh::Int64 = length(basis.shells)
  ioff::Array{Int64,1} = map((x) -> x*(x-1)/2, collect(1:basis.norb*(basis.norb+1)))

  F = zeros(basis.norb,basis.norb)
  mutex = Base.Threads.Mutex()

  #for bra_pairs::Int64 in nsh*(nsh+1)/2:-1:1
  for bra_pairs::Int64 in 1:nsh*(nsh+1)/2
    if(MPI.Comm_rank(comm) == bra_pairs%MPI.Comm_size(comm))
      ish::Int64 = ceil(((-1+sqrt(1+8*bra_pairs))/2))
      jsh::Int64 = bra_pairs - ioff[ish]

      if (ish < jsh) continue end

      ijsh::Int64 = index(ish,jsh)

      #Threads.@threads for ket_pairs::Int64 in bra_pairs:-1:1
      Threads.@threads for ket_pairs::Int64 in 1:bra_pairs
        ksh::Int64 = ceil(((-1+sqrt(1+8*ket_pairs))/2))
        lsh::Int64 = ket_pairs - ioff[ksh]

        if (ksh < lsh) continue end

        klsh::Int64 = index(ksh,lsh)
        if (klsh > ijsh) continue end

		bra::ShPair = ShPair(basis.shells[ish], basis.shells[jsh])
		ket::ShPair = ShPair(basis.shells[ksh], basis.shells[lsh])
		quartet::ShQuartet = ShQuartet(bra,ket)

        qnum_ij::Int64 = ish*(ish-1)/2 + jsh
		qnum_kl::Int64 = ksh*(ksh-1)/2 + lsh
		quartet_num ::Int64= qnum_ij*(qnum_ij-1)/2 + qnum_kl
        #println("QUARTET: $ish, $jsh, $ksh, $lsh ($quartet_num):")

		eri_batch = shellquart(D, quartet, tei,
            mutex, quartet_num)

	    F_priv::Array{T,2} = zeros(basis.norb,basis.norb)
		#if (max(eri_batch...) >= 1E-10)
        F_priv = dirfck(D, eri_batch, quartet, ish, jsh, ksh, lsh)
        #end

		lock(mutex)
		F += F_priv
		unlock(mutex)
      end
    end
  end

  for iorb::Int64 in 1:basis.norb, jorb::Int64 in 1:basis.norb
    if (iorb != jorb)
      F[iorb,jorb] /= 2
    end
  end

  return F
end

function shellquart(D::Array{T,2},quartet::ShQuartet,
  tei_file::HDF5File, mutex, quartet_num::Int64) where {T<:AbstractFloat}

  lock(mutex)
  eri_batch::Array{Float64,1} = read(tei_file, "Integrals/$quartet_num")
  unlock(mutex)

  return eri_batch
end

function dirfck(D::Array{T,2}, eri_batch::Array{T,1},
  quartet::ShQuartet, ish, jsh, ksh, lsh) where {T<:AbstractFloat}

  norb = size(D)[1]

  F_priv::Array{T,2} = fill(0.0,(norb,norb))

  nμ::Int64 = quartet.bra.sh_a.nbas
  nν::Int64 = quartet.bra.sh_b.nbas
  nλ::Int64 = quartet.ket.sh_a.nbas
  nσ::Int64 = quartet.ket.sh_b.nbas

  pμ::Int64 = quartet.bra.sh_a.pos
  pν::Int64 = quartet.bra.sh_b.pos
  pλ::Int64 = quartet.ket.sh_a.pos
  pσ::Int64 = quartet.ket.sh_b.pos

  μνλσ::Int64 = 0

  for μμ::Int64 in pμ:pμ+(nμ-1), νν::Int64 in pν:pν+(nν-1)
    μ::Int64, ν::Int64 = μμ,νν
    if (μμ < νν) continue end

    μν::Int64 = index(μμ,νν)

    for λλ::Int64 in pλ:pλ+(nλ-1), σσ::Int64 in pσ:pσ+(nσ-1)
      λ::Int64, σ::Int64 = λλ,σσ
      if (λλ < σσ) continue end

      λσ::Int64 = index(λλ,σσ)

      #if (μν < λσ) continue end

      #println("$μ, $ν, $λ, $σ")

      if (μν < λσ)
        two_shell::Bool = nμ == nν
        two_shell = two_shell || (nμ == nλ)
        two_shell = two_shell || (nμ == nσ)
        two_shell = two_shell || (nν == nλ)
        two_shell = two_shell || (nν == nσ)
        two_shell = two_shell || (nλ == nσ)

        three_shell::Bool = nμ == nν && nν == nλ
        three_shell = three_shell || (nμ == nν && nν == nσ)
        three_shell = three_shell || (nμ == nλ && nλ == nσ)
        three_shell = three_shell || (nν == nλ && nλ == nσ)

        four_shell::Bool = nμ == nν
        four_shell = four_shell && (nν == nλ)
        four_shell = four_shell && (nλ == nσ)

        if four_shell
          three_same::Bool = ish == jsh && jsh == ksh
          three_same = three_same || (ish == jsh && jsh == lsh)
          three_same = three_same || (ish == ksh && ksh == lsh)
          three_same = three_same || (jsh == ksh && ksh == lsh)

          four_same::Bool = ish == jsh
          four_same = four_same && jsh == ksh
          four_same = four_same && ksh == lsh

          if four_same
              if (μμ != νν && μμ != λλ && μμ != σσ &&
                νν != λλ && νν != σσ && λλ != σσ)
                μ,ν,λ,σ = λλ,σσ,μμ,νν
              else
                continue
              end
          elseif three_same
            if (μμ != λλ && νν != σσ)
              μ,ν,λ,σ = λλ,σσ,μμ,νν
            else
              continue
            end
          else
            continue
          end
        elseif three_shell
          if (μμ != λλ && νν != σσ)
              μ,ν,λ,σ = λλ,σσ,μμ,νν
          else
            continue
          end
        elseif two_shell
          if (μμ != λλ && νν != σσ)
            μ,ν,λ,σ = λλ,σσ,μμ,νν
          else
            continue
          end
        end
      end

      μνλσ += 1

	  eri::T = eri_batch[μνλσ]
      #eri::T = 0
      if (abs(eri) <= 1E-10) continue end

      Dij = D[μ,ν]
      #println("$μ, $ν, $λ, $σ, $eri, $Dij")
	  eri *= (μ == ν) ? 0.5 : 1.0
	  eri *= (λ == σ) ? 0.5 : 1.0
	  eri *= ((μ == λ) && (ν == σ)) ? 0.5 : 1.0

	  F_priv[λ,σ] += 4.0 * D[μ,ν] * eri
	  F_priv[μ,ν] += 4.0 * D[λ,σ] * eri
      F_priv[μ,λ] -= D[ν,σ] * eri
	  F_priv[μ,σ] -= D[ν,λ] * eri
	  F_priv[max(ν,λ),min(ν,λ)] -= D[max(μ,σ),min(μ,σ)] * eri
	  F_priv[max(ν,σ),min(ν,σ)] -= D[max(μ,λ),min(μ,λ)] * eri

	  F_priv[σ,λ] = F_priv[λ,σ]
	  F_priv[ν,μ] = F_priv[μ,ν]
	  F_priv[λ,μ] = F_priv[μ,λ]
	  F_priv[σ,μ] = F_priv[μ,σ]
	  F_priv[min(λ,ν),max(λ,ν)] = F_priv[max(ν,λ),min(ν,λ)]
	  F_priv[min(σ,ν),max(σ,ν)] = F_priv[max(ν,σ),min(ν,σ)]
    end
  end

  return F_priv
end
