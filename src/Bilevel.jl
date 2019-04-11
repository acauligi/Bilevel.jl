module Bilevel

__precompile__(false)

export Obstacle,
       Contact,
       Environment,
       EnvironmentJacobian,
       EnvironmentJacobianCache,
       SimData,
       get_sim_data_indirect,
       get_sim_data_direct,
       get_trajopt_data_indirect,
       add_eq!,
       add_ineq!,
       add_obj!,
       simulate,
       trajopt
                  
using Test
using StaticArrays
using LinearAlgebra
using ForwardDiff
using DiffResults
using Ipopt
using Rotations
using GeometryTypes
using RigidBodyDynamics
using MechanismGeometries
using Compat
using Base.Threads

include("obstacle.jl")
include("contact.jl")
include("environment.jl")
include("selector.jl")
include("simulation.jl")
include("simulation_indirect.jl")
include("simulation_direct.jl")
include("trajopt.jl")
include("trajopt_indirect.jl")
include(joinpath("solvers", "snopt.jl"))
include(joinpath("solvers", "auglag.jl"))
include(joinpath("solvers", "svd.jl"))
include(joinpath("solvers", "autodiff.jl"))

end # module
