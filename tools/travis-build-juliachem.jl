using Pkg                                                                    
                                                                                
Pkg.add(PackageSpec(url="https://github.com/davpoolechem/MATH.jl.git"))      
Pkg.instantiate()                                                                         
Pkg.add(PackageSpec(url="https://github.com/davpoolechem/JCModules.jl.git")) 
Pkg.instantiate()                                                                         
Pkg.add(PackageSpec(url="https://github.com/davpoolechem/JuliaChem.jl")) 
Pkg.instantiate()                                                                         
