function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing
    precompile(Tuple{typeof(Blosc.__init__)})
    precompile(Tuple{typeof(Blosc.check_deps)})
end
