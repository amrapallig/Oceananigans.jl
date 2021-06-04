using Oceananigans.Architectures: architecture, device_event
using Oceananigans.BoundaryConditions: DefaultBoundaryCondition
using Oceananigans.AbstractOperations: KernelFunctionOperation
using Oceananigans.BuoyancyModels: ∂z_b, top_buoyancy_flux
using Oceananigans.Operators: ℑzᵃᵃᶜ

function hydrostatic_turbulent_kinetic_energy_tendency end

struct TKEBasedVerticalDiffusivity{TD, CK, CD, CL, CA, CQ} <: AbstractTurbulenceClosure{TD}
    diffusivity_scaling :: CK
    dissipation_parameter :: CD
    mixing_length_parameter :: CL
    convective_adjustment :: CA
    surface_model :: CQ

    function TKEBasedVerticalDiffusivity{TD}(
        diffusivity_scaling :: CK,
        dissipation_parameter :: CD,
        mixing_length_parameter :: CL,
        convective_adjustment :: CA,
        surface_model :: CQ) where {TD, CK, CD, CL, CA, CQ}

        return new{TD, CK, CD, CL, CA, CQ}(diffusivity_scaling, dissipation_parameter,
                                           mixing_length_parameter, convective_adjustment, surface_model)
    end
end

"""
    TKEBasedVerticalDiffusivity(FT=Float64;
                                diffusivity_scaling = RiDependentDiffusivityScaling{FT}(),
                                dissipation_parameter = 2.91,
                                mixing_length_parameter = 1.16,
                                convective_adjustment = nothing,
                                surface_model = TKESurfaceFlux{FT}(),
                                time_discretization::TD = ExplicitTimeDiscretization())

Returns the `TKEBasedVerticalDiffusivity` turbulence closure for vertical mixing by
small-scale ocean turbulence based on the prognostic evolution of subgrid
Turbulent Kinetic Energy (TKE).

`TKEBasedVerticalDiffusivity` is a downgradient, diffusive
closure formulated with three different eddy diffusivities for momentum, tracers, and TKE.
Each eddy diffusivity is the product of a diffusivity "scaling", a mixing length, and a turbulent
velocity scale which is the square root of the local TKE, such that

```math
Kᵠ = Cᵠ ℓ √e
```

where `Kᵠ` is the eddy diffusivity of `ϕ` where `ϕ` is either `u` (for momentum) `c` (for tracers), or
`e` (for TKE). `Cᵠ` is the diffusivity scaling for `ϕ`, `ℓ` is the mixing length
and `√e` is the turbulent velocity scale. The mixing length `ℓ` is modeled as

```math
ℓ = min(ℓᵇ, ℓᶻ)
```

where `ℓᵇ = Cᵇ * √e / N` and `ℓᶻ` is the distance to the nearest boundary.
`TKEBasedVerticalDiffusivity` also invokes a model for the flux of TKE across the numerical
ocean surface due to unstable buoyancy forcing and wind stress.

The `TKEBasedVerticalDiffusivity` is formulated in terms of 12 free parameters. These parameters
are _experimentally_ calibrated against large eddy simulations of ocean surface boundary layer turbulence
in idealized scenarios involving monotonic boundary layer deepening into variable stratification
due to constant surface momentum fluxes and/or destabilizing surface buoyancy flux.
This calibration has not been peer-reviewed, may be inaccurate and imperfect, and may not
be appropriate for three-dimensional ocean simulations.

See https://github.com/CliMA/LESbrary.jl for more information about the large eddy simulations.

The calibration procedure is not documented and is part of ongoing research.
The calibration was performed using a combination of Markov Chain Monte Carlo (MCMC)-based simulated
annealing and noisy Ensemble Kalman Inversion methods.

The one positional argument determines the floating point type of the free parameters
of `TKEBasedVerticalDiffusivity`. The default is `Float64`.

Keyword arguments
=================

* `diffusivity_scaling` : A group of parameters that scale the eddy diffusivity for momentum, tracers, and TKE.
                          The default is `RiDependentDiffusivityScaling{FT}()`, which represents a group of
                          parameters that implement a "smoothed step function" scaling that varies with the
                          local gradient Richardson number `Ri = ∂z(b) / (∂z(u)² + ∂z(v)²)`.

* `dissipation_parameter` : Parameter `Cᴰ` in the closure `ϵ = Cᴰ * e^3/2 / ℓ` that models the dissipation of TKE,
                            `ϵ`, appearing in the TKE evolution equation. The default is 2.91 via calibration
                            against large eddy simulations.
                          
* `mixing_length_parameter` : Parameter `Cᵇ` that multiplies the "buoyancy mixing length" `ℓᵇ = Cᵇ * √e / N`,
                            that appears in `TKEBasedVerticalDiffusivity`'s mixing length model.
                            The default is 1.16 via calibration against large eddy simulations.

* `convective_adjustment` : A group of parameters that controls the a convective adjustment submodel of
                            the parameterization. The default is nothing, meaning that no convective adjustment
                            model is used.

* `time_discretization` : Either `ExplicitTimeDiscretization` or `VerticallyImplicitTimeDiscretization`.

"""
function TKEBasedVerticalDiffusivity(FT=Float64;
                                     diffusivity_scaling = RiDependentDiffusivityScaling{FT}(),
                                     dissipation_parameter = 2.91,
                                     mixing_length_parameter = 1.16,
                                     convective_adjustment = ConvectiveAdjustmentParameters{FT}(),
                                     surface_model = TKESurfaceFlux{FT}(),
                                     time_discretization::TD = VerticallyImplicitTimeDiscretization()) where TD

    @warn "TKEBasedVerticalDiffusivity is an experimental and unvalidated turbulence closure."

    dissipation_parameter = convert(FT, dissipation_parameter)
    mixing_length_parameter = convert(FT, mixing_length_parameter)
    diffusivity_scaling = convert_eltype(FT, diffusivity_scaling)
    surface_model = convert_eltype(FT, surface_model)
    convective_adjustment = convert_eltype(FT, convective_adjustment)

    return TKEBasedVerticalDiffusivity{TD}(diffusivity_scaling,
                                           dissipation_parameter,
                                           mixing_length_parameter,
                                           convective_adjustment,
                                           surface_model)
end

const TKEVD = TKEBasedVerticalDiffusivity

"""
    struct RiDependentDiffusivityScaling{FT}

A diffusivity model in which momentum, tracers, and TKE
each have Richardson-number-dependent diffusivities with
free parameter of type `FT`.

The Richardson number is

    ``Ri = ∂z B / ( (∂z U)² + (∂z V)² )`` ,

where ``B`` is buoyancy and ``∂z`` denotes a vertical derviative.
The Richardson-number dependent diffusivities are multiplied by the stability
function

    ``σ(Ri) = σ⁻ + (σ⁺ - σ⁻) * step(Ri, Riᶜ, Riʷ)``

where ``σ⁰``, ``σᵟ``, ``Riᶜ``, and ``Riʷ`` are free parameters,
and ``step`` is a smooth step function defined by

    ``step(x, c, w) = (1 + tanh((x - c) / w)) / 2``.

The 8 free parameters in `RiDependentDiffusivityScaling` have been _experimentally_ calibrated
against large eddy simulations of ocean surface boundary layer turbulence in idealized
scenarios involving monotonic boundary layer deepening into variable stratification
due to constant surface momentum fluxes and/or destabilizing surface buoyancy flux.
See https://github.com/CliMA/LESbrary.jl for more information about the large eddy simulations.
The calibration was performed using a combination of Markov Chain Monte Carlo (MCMC)-based simulated
annealing and noisy Ensemble Kalman Inversion methods.
"""
Base.@kwdef struct RiDependentDiffusivityScaling{FT}
    Cᴷu⁻  :: FT = 0.15
    Cᴷu⁺  :: FT = 0.73
    Cᴷc⁻  :: FT = 0.40
    Cᴷc⁺  :: FT = 1.77
    Cᴷe⁻  :: FT = 0.13
    Cᴷe⁺  :: FT = 1.22
    CᴷRiʷ :: FT = 0.72
    CᴷRiᶜ :: FT = 0.76
end

"""
    struct TKESurfaceFlux{FT}

A model for the flux of TKE across the numerical ocean surface with
free parameters of type `FT`, parameterized in
terms of the kinematic surface stress and buoyancy flux:

```math
Qᵉ = - Cᴰ * (Cᵂu★ * u★³ + CᵂwΔ * w★³)
```

where `Qᵉ` is the surface flux of TKE, `Cᴰ = TKEBasedVerticalDiffusivity.dissipation_parameter`,
`u★ = (Qᵘ^2 + Qᵛ^2)^(1/4)` is the friction velocity and `w★ = (Qᵇ * Δz)^(1/3)` is the
turbulent velocity scale associated with the surface vertical grid spacing `Δz` and the
surface buoyancy flux `Qᵇ`.
             
The 2 free parameters in `TKESurfaceFlux` have been _experimentally_ calibrated
against large eddy simulations of ocean surface boundary layer turbulence in idealized
scenarios involving monotonic boundary layer deepening into variable stratification
due to constant surface momentum fluxes and/or destabilizing surface buoyancy flux.
See https://github.com/CliMA/LESbrary.jl for more information about the large eddy simulations.
The calibration was performed using a combination of Markov Chain Monte Carlo (MCMC)-based simulated
annealing and noisy Ensemble Kalman Inversion methods.
"""
Base.@kwdef struct TKESurfaceFlux{FT}
    Cᵂu★ :: FT = 3.62
    CᵂwΔ :: FT = 1.31
end

#####
##### TKE top boundary condition
#####

""" Computes the friction velocity based on fluxes of u and v. """
@inline function friction_velocity(i, j, grid, clock, fields, velocity_bcs)
    FT = eltype(grid)
    Qᵘ = getbc(velocity_bcs.u, i, j, grid, clock, fields) 
    Qᵛ = getbc(velocity_bcs.v, i, j, grid, clock, fields) 
    return sqrt(sqrt(Qᵘ^2 + Qᵛ^2))
end

@inline function top_convective_turbulent_velocity³(i, j, grid, clock, fields, buoyancy, top_tracer_bcs)
    FT = eltype(grid)
    Qᵇ = top_buoyancy_flux(i, j, grid, buoyancy, top_tracer_bcs, clock, fields)
    Δz = Δzᵃᵃᶜ(i, j, grid.Nz, grid)
    return max(zero(FT), Qᵇ) * Δz   
end

@inline top_tke_flux(i, j, grid, clock, fields, closures::Tuple, parameters) =
    top_tke_flux(i, j, grid, clock, fields, closures[1], parameters)

@inline function top_tke_flux(i, j, grid, clock, fields, closure::TKEVD, parameters)
    buoyancy = parameters.buoyancy
    top_tracer_bcs = parameters.top_tracer_boundary_conditions
    top_velocity_bcs = parameters.top_velocity_boundary_conditions

    wΔ³ = top_convective_turbulent_velocity³(i, j, grid, clock, fields, buoyancy, top_tracer_bcs)
    u★ = friction_velocity(i, j, grid, clock, fields, top_velocity_bcs)

    Cᴰ = closure.dissipation_parameter
    Cᵂu★ = closure.surface_model.Cᵂu★
    CᵂwΔ = closure.surface_model.CᵂwΔ

    return - Cᴰ * (Cᵂu★ * u★^3 + CᵂwΔ * wΔ³)
end

Base.@kwdef struct ConvectiveAdjustmentParameters{FT}
    Cᴬu :: FT = 1.0
    Cᴬc :: FT = 100.0
    Cᴬe :: FT = 100.0
end

#####
##### Utilities for model constructors
#####

for S in (:RiDependentDiffusivityScaling, :TKESurfaceFlux, :ConvectiveAdjustmentParameters)
    @eval @inline convert_eltype(::Type{FT}, s::$S) where FT = $S{FT}(; Dict(p => getproperty(s, p) for p in propertynames(s))...)
    @eval @inline convert_eltype(::Type{FT}, s::$S{FT}) where FT = s
end

""" Infer tracer boundary conditions from user_bcs and tracer_names. """
function top_tracer_boundary_conditions(grid, tracer_names, user_bcs)
    user_bc_names = keys(user_bcs)
    default_top_bc = DefaultBoundaryCondition(topology(grid, 3), Center)

    tracer_bcs = Tuple(name ∈ user_bc_names ? user_bcs[name].top : default_top_bc
                       for name in tracer_names)

    return NamedTuple{tracer_names}(tracer_bcs)
end

""" Infer velocity boundary conditions from user_bcs and tracer_names. """
function top_velocity_boundary_conditions(grid, user_bcs)

    user_bc_names = keys(user_bcs)

    u_top_bc = :u ∈ user_bc_names ? user_bcs.u.top : DefaultBoundaryCondition(topology(grid, 3), Center)
    v_top_bc = :v ∈ user_bc_names ? user_bcs.v.top : DefaultBoundaryCondition(topology(grid, 3), Center)

    return (u=u_top_bc, v=v_top_bc)
end

""" Add TKE boundary conditions specific to TKEBasedVerticalDiffusivity. """
function add_closure_specific_boundary_conditions(closure::TKEVD,
                                                  user_bcs,
                                                  grid,
                                                  tracer_names,
                                                  buoyancy)

    top_tracer_bcs = top_tracer_boundary_conditions(grid, tracer_names, user_bcs)
    top_velocity_bcs = top_velocity_boundary_conditions(grid, user_bcs)

    parameters = (buoyancy = buoyancy,
                  top_tracer_boundary_conditions = top_tracer_bcs,
                  top_velocity_boundary_conditions = top_velocity_bcs)

    top_tke_bc = FluxBoundaryCondition(top_tke_flux, discrete_form=true, parameters=parameters)

    if :e ∈ keys(user_bcs)
        @warn "Replacing top boundary conditions for tracer `e` with " *
              "boundary condition specific to $(typeof(closure).name.wrapper)"

        e_bcs = user_bcs[:e]
        
        tke_bcs = TracerBoundaryConditions(grid,
                                           top = top_tke_bc,
                                           bottom = e_bcs.bottom,
                                           north = e_bcs.north,
                                           south = e_bcs.south,
                                           east = e_bcs.east,
                                           west = e_bcs.west)

    else
        tke_bcs = TracerBoundaryConditions(grid, top=top_tke_bc)
    end

    new_boundary_conditions = merge(user_bcs, (e = tke_bcs,))

    return new_boundary_conditions
end

function DiffusivityFields(arch, grid, tracer_names, bcs, closure::TKEVD)

    Kᵘ_bcs = :Kᵘ ∈ keys(bcs) ? bcs[:Kᵘ] : DiffusivityBoundaryConditions(grid)
    Kᶜ_bcs = :Kᶜ ∈ keys(bcs) ? bcs[:Kᶜ] : DiffusivityBoundaryConditions(grid)
    Kᵉ_bcs = :Kᵉ ∈ keys(bcs) ? bcs[:Kᵉ] : DiffusivityBoundaryConditions(grid)

    Kᵘ = CenterField(arch, grid, Kᵘ_bcs)
    Kᶜ = CenterField(arch, grid, Kᶜ_bcs)
    Kᵉ = CenterField(arch, grid, Kᵉ_bcs)

    return (; Kᵘ, Kᶜ, Kᵉ)
end        
            
function with_tracers(tracer_names, closure::TKEVD)
    :e ∈ tracer_names || error("Tracers must contain :e to represent turbulent kinetic energy for `TKEBasedVerticalDiffusivity`.")
    return closure
end

#####
##### Mixing length
#####

@inline surface(i, j, k, grid)                = znode(Center(), Center(), Face(), i, j, grid.Nz+1, grid)
@inline bottom(i, j, k, grid)                 = znode(Center(), Center(), Face(), i, j, 1, grid)
@inline depthᶜᶜᶜ(i, j, k, grid)               = surface(i, j, k, grid) - znode(Center(), Center(), Center(), i, j, k, grid)
@inline height_above_bottomᶜᶜᶜ(i, j, k, grid) = znode(Center(), Center(), Center(), i, j, k, grid) - bottom(i, j, k, grid)

@inline wall_vertical_distanceᶜᶜᶜ(i, j, k, grid) = min(depthᶜᶜᶜ(i, j, k, grid), height_above_bottomᶜᶜᶜ(i, j, k, grid))

@inline function sqrt_∂z_b(i, j, k, grid, buoyancy, tracers)
    FT = eltype(grid)
    N² = ∂z_b(i, j, k, grid, buoyancy, tracers)
    N²⁺ = max(zero(FT), N²)
    return sqrt(N²⁺)  
end

@inline function buoyancy_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
    FT = eltype(grid)
    Cᵇ = closure.mixing_length_parameter
    N⁺ = ℑzᵃᵃᶜ(i, j, k, grid, sqrt_∂z_b, buoyancy, tracers)

    @inbounds e⁺ = max(zero(FT), e[i, j, k])

    return @inbounds ifelse(N⁺ == 0, FT(Inf), Cᵇ * sqrt(e⁺) / N⁺)
end

@inline function dissipation_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
    ℓᶻ = wall_vertical_distanceᶜᶜᶜ(i, j, k, grid)
    ℓᵇ = buoyancy_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
    ℓ = min(ℓᶻ, ℓᵇ)
    ℓ_min = Δzᵃᵃᶜ(i, j, k, grid) / 2 # minimum mixing length...
    return max(ℓ_min, ℓ)
end

#####
##### "Stable" scales
#####

@inline ϕ²(i, j, k, grid, ϕ, args...) = ϕ(i, j, k, grid, args...)^2

@inline function Riᶜᶜᶜ(i, j, k, grid, velocities, tracers, buoyancy)
    FT = eltype(grid)
    ∂z_u² = ℑxzᶜᵃᶜ(i, j, k, grid, ϕ², ∂zᵃᵃᶠ, velocities.u)
    ∂z_v² = ℑyzᵃᶜᶜ(i, j, k, grid, ϕ², ∂zᵃᵃᶠ, velocities.v)
    N² = ℑzᵃᵃᶜ(i, j, k, grid, ∂z_b, buoyancy, tracers)
    return ifelse(N² == 0, zero(FT), N² / (∂z_u² + ∂z_v²))
end

@inline step(x, c, w) = (1 + tanh((x - c) / w)) / 2

@inline scale(Ri, σ⁻, σ⁺, c, w) = σ⁻ + (σ⁺ - σ⁻) * step(Ri, c, w)

@inline function momentum_diffusivity_scale(i, j, k, grid, ::Nothing, closure, velocities, tracers, buoyancy)
    Ri = Riᶜᶜᶜ(i, j, k, grid, velocities, tracers, buoyancy)
    return scale(Ri,
                 closure.diffusivity_scaling.Cᴷu⁻,
                 closure.diffusivity_scaling.Cᴷu⁺,
                 closure.diffusivity_scaling.CᴷRiᶜ,
                 closure.diffusivity_scaling.CᴷRiʷ)
end

@inline function tracer_diffusivity_scale(i, j, k, grid, ::Nothing, closure, velocities, tracers, buoyancy)
    Ri = Riᶜᶜᶜ(i, j, k, grid, velocities, tracers, buoyancy)
    return scale(Ri,
                 closure.diffusivity_scaling.Cᴷc⁻,
                 closure.diffusivity_scaling.Cᴷc⁺,
                 closure.diffusivity_scaling.CᴷRiᶜ,
                 closure.diffusivity_scaling.CᴷRiʷ)
end

@inline function TKE_diffusivity_scale(i, j, k, grid, ::Nothing, closure, velocities, tracers, buoyancy)
    Ri = Riᶜᶜᶜ(i, j, k, grid, velocities, tracers, buoyancy)
    return scale(Ri,
                 closure.diffusivity_scaling.Cᴷe⁻,
                 closure.diffusivity_scaling.Cᴷe⁺,
                 closure.diffusivity_scaling.CᴷRiᶜ,
                 closure.diffusivity_scaling.CᴷRiʷ)
end

#####
##### "Unstable" scales
#####

@inline is_unstableᶜᶜᶜ(i, j, k, grid, tracers, buoyancy) = ℑzᵃᵃᶜ(i, j, k, grid, ∂z_b, buoyancy, tracers) < 0

@inline function momentum_diffusivity_scale(i, j, k, grid, convective_adjustment, closure, velocities, tracers, buoyancy)
    stable_scale = momentum_diffusivity_scale(i, j, k, grid, nothing, closure, velocities, tracers, buoyancy)
    convective_scale = convective_adjustment.Cᴬu
    ijk_unstable = is_unstableᶜᶜᶜ(i, j, k, grid, tracers, buoyancy)
    return ifelse(ijk_unstable, convective_scale, stable_scale)
end

@inline function tracer_diffusivity_scale(i, j, k, grid, convective_adjustment, closure, velocities, tracers, buoyancy)
    stable_scale = tracer_diffusivity_scale(i, j, k, grid, nothing, closure, velocities, tracers, buoyancy)
    convective_scale = convective_adjustment.Cᴬc
    ijk_unstable = is_unstableᶜᶜᶜ(i, j, k, grid, tracers, buoyancy)
    return ifelse(ijk_unstable, convective_scale, stable_scale)
end

@inline function TKE_diffusivity_scale(i, j, k, grid, convective_adjustment, closure, velocities, tracers, buoyancy)
    stable_scale = TKE_diffusivity_scale(i, j, k, grid, nothing, closure, velocities, tracers, buoyancy)
    convective_scale = convective_adjustment.Cᴬe
    ijk_unstable = is_unstableᶜᶜᶜ(i, j, k, grid, tracers, buoyancy)
    return ifelse(ijk_unstable, convective_scale, stable_scale)
end

#####
##### Diffusivities
#####

@inline turbulent_velocity(i, j, k, grid, e) = @inbounds sqrt(max(zero(eltype(grid)), e[i, j, k]))

@inline function unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, ::Nothing, closure, e, tracers, buoyancy)
    ℓ = dissipation_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
    u★ = turbulent_velocity(i, j, k, grid, e)
    return ℓ * u★
end

@inline function convective_diffusivityᶜᶜᶜ(i, j, k, grid, convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    @inbounds e² = max(zero(eltype(grid)), e[i, j, k])^2
    Qᵇ = top_buoyancy_flux(i, j, grid, buoyancy, top_tracer_bcs, clock, merge(velocities, tracers))
    return ifelse(Qᵇ > 0, e² / Qᵇ, zero(eltype(grid)))
end

@inline function unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    stable_K = unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, nothing, closure, e, tracers, buoyancy)
    unstable_K = convective_diffusivityᶜᶜᶜ(i, j, k, grid, convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    ijk_unstable = is_unstableᶜᶜᶜ(i, j, k, grid, tracers, buoyancy)
    return ifelse(ijk_unstable, unstable_K, stable_K)
end

#####
##### Diffusivity field utilities
#####

function calculate_diffusivities!(diffusivities, closure::TKEVD, model)

    arch = model.architecture
    grid = model.grid
    velocities = model.velocities
    tracers = model.tracers
    buoyancy = model.buoyancy
    clock = model.clock
    e = tracers.e

    tracer_names = keys(model.tracers)
    top_tracer_bc_tuple = Tuple(c.boundary_conditions.top for c in model.tracers)
    top_tracer_bcs = NamedTuple{tracer_names}(top_tracer_bc_tuple)

    event = launch!(arch, grid, :xyz,
                    calculate_tke_diffusivities!, diffusivities, grid,
                    closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock,
                    dependencies=device_event(arch))

    wait(device(arch), event)

    return nothing
end

@kernel function calculate_tke_diffusivities!(diffusivities, grid, args...)
    i, j, k, = @index(Global, NTuple)
    @inbounds begin
        diffusivities.Kᵘ[i, j, k] = Kuᶜᶜᶜ(i, j, k, grid, args...)
        diffusivities.Kᶜ[i, j, k] = Kcᶜᶜᶜ(i, j, k, grid, args...)
        diffusivities.Kᵉ[i, j, k] = Keᶜᶜᶜ(i, j, k, grid, args...)
    end
end

@inline function Kuᶜᶜᶜ(i, j, k, grid, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    K = unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, closure.convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    σu = momentum_diffusivity_scale(i, j, k, grid, closure.convective_adjustment, closure, velocities, tracers, buoyancy)
    return σu * K
end

@inline function Kcᶜᶜᶜ(i, j, k, grid, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    K = unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, closure.convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    σc = tracer_diffusivity_scale(i, j, k, grid, closure.convective_adjustment, closure, velocities, tracers, buoyancy)
    return σc * K
end

@inline function Keᶜᶜᶜ(i, j, k, grid, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    K = unscaled_diffusivityᶜᶜᶜ(i, j, k, grid, closure.convective_adjustment, closure, e, velocities, tracers, buoyancy, top_tracer_bcs, clock)
    σe = TKE_diffusivity_scale(i, j, k, grid, closure.convective_adjustment, closure, velocities, tracers, buoyancy)
    return σe * K
end

#####
##### Terms in the turbulent kinetic energy equation, all at cell centers
#####

@inline ϕ²(i, j, k, grid, ϕ) = ϕ(i, j, k, grid)^2

@inline function shear_production(i, j, k, grid, closure::TKEVD, diffusivities, clock, velocities, tracers, buoyancy)
    ∂z_u² = ℑxzᶜᵃᶜ(i, j, k, grid, ϕ², ∂zᵃᵃᶠ, velocities.u)
    ∂z_v² = ℑyzᵃᶜᶜ(i, j, k, grid, ϕ², ∂zᵃᵃᶠ, velocities.v)
    @inbounds Ku = diffusivities.Kᵘ[i, j, k]
    return Ku * (∂z_u² + ∂z_v²)
end

@inline function buoyancy_flux(i, j, k, grid, closure::TKEVD, diffusivities, velocities, tracers, buoyancy)
    @inbounds Kc = diffusivities.Kᶜ[i, j, k]
    N² = ℑzᵃᵃᶜ(i, j, k, grid, ∂z_b, buoyancy, tracers)
    return - Kc * N²
end

@inline function dissipation(i, j, k, grid, closure::TKEVD, tracers, buoyancy)
    e = tracers.e
    FT = eltype(grid)
    three_halves = FT(3/2)
    @inbounds ẽ³² = abs(e[i, j, k])^three_halves # abs ensures that negative TKE damps to zero.

    ℓ = dissipation_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
    Cᴰ = closure.dissipation_parameter

    return Cᴰ * ẽ³² / ℓ
end

# Closure tuple support
# Enforced by HydrostaticFreeSurfaceModel constructor Heuristic...
@inline shear_production(i, j, k, grid, closures::Tuple, diffusivities::Tuple, args...) = shear_production(i, j, k, grid, closures[1], diffusivities[1], args...)
@inline buoyancy_flux(i, j, k, grid, closures::Tuple, diffusivities::Tuple, args...) = buoyancy_flux(i, j, k, grid, closures[1], diffusivities[1], args...)
@inline dissipation(i, j, k, grid, closures::Tuple, args...) = dissipation(i, j, k, grid, closures[1], args...)

#####
##### Viscous flux, diffusive fluxes, plus shenanigans for diffusive fluxes of TKE (eg TKE "transport")
#####

# Special "index type" alternative to Val for dispatch
struct TKETracerIndex{N} end
@inline TKETracerIndex(N) = TKETracerIndex{N}()

@inline function viscous_flux_uz(i, j, k, grid, closure::TKEVD, clock, velocities, diffusivities, tracers, buoyancy)
    Ku = ℑxzᶠᵃᶠ(i, j, k, grid, diffusivities.Kᵘ)
    return - Ku * ∂zᵃᵃᶠ(i, j, k, grid, velocities.u)
end

@inline function viscous_flux_vz(i, j, k, grid, closure::TKEVD, clock, velocities, diffusivities, tracers, buoyancy)
    Kv = ℑyzᵃᶠᶠ(i, j, k, grid, diffusivities.Kᵘ)
    return - Kv * ∂zᵃᵃᶠ(i, j, k, grid, velocities.v)
end

@inline function viscous_flux_wz(i, j, k, grid, closure::TKEVD, clock, velocities, diffusivities, tracers, buoyancy)
    @inbounds Kw = diffusivities.Kᵘ[i, j, k]
    return - Kw * ∂zᵃᵃᶜ(i, j, k, grid, velocities.w)
end

@inline function diffusive_flux_z(i, j, k, grid, closure::TKEVD, c, tracer_index, clock, diffusivities, tracers, buoyancy, velocities)
    Kc = ℑzᵃᵃᶠ(i, j, k, grid, diffusivities.Kᶜ)
    return - Kc * ∂zᵃᵃᶠ(i, j, k, grid, c)
end

# Diffusive flux of TKE!
@inline function diffusive_flux_z(i, j, k, grid, closure::TKEVD, e, ::TKETracerIndex, clock, diffusivities, tracers, buoyancy, velocities)
    Ke = ℑzᵃᵃᶠ(i, j, k, grid, diffusivities.Kᵉ)
    return - Ke * ∂zᵃᵃᶠ(i, j, k, grid, e)
end

# "Translations" for diffusive transport by non-TKEVD closures
@inline diffusive_flux_x(i, j, k, grid, closure, e, ::TKETracerIndex{N}, args...) where N = diffusive_flux_x(i, j, k, grid, closure, e, Val(N), args...)
@inline diffusive_flux_y(i, j, k, grid, closure, e, ::TKETracerIndex{N}, args...) where N = diffusive_flux_y(i, j, k, grid, closure, e, Val(N), args...)
@inline diffusive_flux_z(i, j, k, grid, closure, e, ::TKETracerIndex{N}, args...) where N = diffusive_flux_z(i, j, k, grid, closure, e, Val(N), args...)

# Shortcuts --- TKEVD incurs no horizontal transport
@inline diffusive_flux_x(i, j, k, grid, ::TKEVD, args...) = zero(eltype(grid))
@inline diffusive_flux_y(i, j, k, grid, ::TKEVD, args...) = zero(eltype(grid))

# Disambiguate
@inline diffusive_flux_x(i, j, k, grid, ::TKEVD, e, ::TKETracerIndex, args...) = zero(eltype(grid))
@inline diffusive_flux_y(i, j, k, grid, ::TKEVD, e, ::TKETracerIndex, args...) = zero(eltype(grid))

#####
##### Support for VerticallyImplicitTimeDiscretization
#####

const VITD = VerticallyImplicitTimeDiscretization

@inline z_viscosity(closure::TKEVD, diffusivities, args...) = diffusivities.Kᵘ

@inline function z_diffusivity(closure::TKEVD, ::Val{tracer_index}, diffusivities, tracers, args...) where tracer_index
    tke_index = findfirst(name -> name === :e, keys(tracers))

    if tracer_index === tke_index
        return diffusivities.Kᵉ
    else
        return diffusivities.Kᶜ
    end
end

const VerticallyBoundedGrid{FT} = AbstractPrimaryGrid{FT, <:Any, <:Any, <:Bounded}

@inline diffusive_flux_z(i, j, k, grid::APG{FT}, ::VITD, closure::TKEVD, args...) where FT = zero(FT)
@inline viscous_flux_uz(i, j, k, grid::APG{FT}, ::VITD, closure::TKEVD, args...) where FT = zero(FT)
@inline viscous_flux_vz(i, j, k, grid::APG{FT}, ::VITD, closure::TKEVD, args...) where FT = zero(FT)

@inline function diffusive_flux_z(i, j, k, grid::VerticallyBoundedGrid{FT}, ::VITD, closure::TKEVD, args...) where FT
    return ifelse(k == 1 || k == grid.Nz+1, 
                  diffusive_flux_z(i, j, k, grid, ExplicitTimeDiscretization(), closure, args...), # on boundaries, calculate fluxes explicitly
                  zero(FT))
end

@inline function viscous_flux_uz(i, j, k, grid::VerticallyBoundedGrid{FT}, ::VITD, closure::TKEVD, args...) where FT
    return ifelse(k == 1 || k == grid.Nz+1, 
                  viscous_flux_uz(i, j, k, grid, ExplicitTimeDiscretization(), closure, args...), # on boundaries, calculate fluxes explicitly
                  zero(FT))
end

@inline function viscous_flux_vz(i, j, k, grid::VerticallyBoundedGrid{FT}, ::VITD, closure::TKEVD, args...) where FT
    return ifelse(k == 1 || k == grid.Nz+1, 
                  viscous_flux_vz(i, j, k, grid, ExplicitTimeDiscretization(), closure, args...), # on boundaries, calculate fluxes explicitly
                  zero(FT))
end

@inline function viscous_flux_wz(i, j, k, grid::VerticallyBoundedGrid{FT}, ::VITD, closure::TKEVD, args...) where FT
    return ifelse(k == 1 || k == grid.Nz+1, 
                  viscous_flux_wz(i, j, k, grid, ExplicitTimeDiscretization(), closure, args...), # on boundaries, calculate fluxes explicitly
                  zero(FT))
end
