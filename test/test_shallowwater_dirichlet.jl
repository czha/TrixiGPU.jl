module TestShallowWaterBoundary # with `nonconservative_terms::True`

using Trixi, TrixiGPU
using OrdinaryDiffEq
using Test, CUDA

# Start testing with a clean environment
outdir = "out"
isdir(outdir) && rm(outdir, recursive = true)

# Test precision of the semidiscretization process
@testset "Test Shallow Water" begin
    @testset "Shallow Water 1D" begin
        equations = ShallowWaterEquations1D(gravity_constant = 9.81, H0 = 3.0)

        initial_condition = initial_condition_convergence_test

        boundary_condition = BoundaryConditionDirichlet(initial_condition)

        volume_flux = (flux_wintermeyer_etal, flux_nonconservative_wintermeyer_etal)
        solver = DGSEM(polydeg = 4,
                       surface_flux = (flux_hll,
                                       flux_nonconservative_fjordholm_etal),
                       volume_integral = VolumeIntegralFluxDifferencing(volume_flux))

        coordinates_min = 0.0
        coordinates_max = sqrt(2.0)
        mesh = TreeMesh(coordinates_min, coordinates_max,
                        initial_refinement_level = 3,
                        n_cells_max = 10_000,
                        periodicity = false)

        semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver,
                                            boundary_conditions = boundary_condition)

        tspan = (0.0, 1.0)

        # Get CPU data
        (; mesh, equations, initial_condition, boundary_conditions, source_terms, solver, cache) = semi

        # Get GPU data
        equations_gpu = deepcopy(equations)
        mesh_gpu, solver_gpu, cache_gpu = deepcopy(mesh), deepcopy(solver), deepcopy(cache)
        boundary_conditions_gpu, source_terms_gpu = deepcopy(boundary_conditions),
                                                    deepcopy(source_terms)

        # Set initial time
        t = t_gpu = 0.0

        # Get initial data
        ode = semidiscretize(semi, tspan)
        u_ode = copy(ode.u0)
        du_ode = similar(u_ode)
        u = Trixi.wrap_array(u_ode, mesh, equations, solver, cache)
        du = Trixi.wrap_array(du_ode, mesh, equations, solver, cache)

        # Copy data to device
        du_gpu, u_gpu = TrixiGPU.copy_to_device!(du, u)
        # Reset data on host
        Trixi.reset_du!(du, solver, cache)

        # Test `cuda_volume_integral!`
        TrixiGPU.cuda_volume_integral!(du_gpu, u_gpu, mesh_gpu,
                                       Trixi.have_nonconservative_terms(equations_gpu),
                                       equations_gpu, solver_gpu.volume_integral, solver_gpu,
                                       cache_gpu)
        Trixi.calc_volume_integral!(du, u, mesh, Trixi.have_nonconservative_terms(equations),
                                    equations, solver.volume_integral, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_prolong2interfaces!`
        TrixiGPU.cuda_prolong2interfaces!(u_gpu, mesh_gpu, equations_gpu, cache_gpu)
        Trixi.prolong2interfaces!(cache, u, mesh, equations, solver.surface_integral, solver)
        interfaces_u_gpu = replace(cache_gpu.interfaces.u, NaN => 0.0)
        interfaces_u = replace(cache.interfaces.u, NaN => 0.0)
        @test interfaces_u_gpu ≈ interfaces_u

        # Test `cuda_interface_flux!`
        TrixiGPU.cuda_interface_flux!(mesh_gpu, Trixi.have_nonconservative_terms(equations_gpu),
                                      equations_gpu, solver_gpu, cache_gpu)
        Trixi.calc_interface_flux!(cache.elements.surface_flux_values, mesh,
                                   Trixi.have_nonconservative_terms(equations), equations,
                                   solver.surface_integral, solver, cache)
        surface_flux_values_gpu = replace(cache_gpu.elements.surface_flux_values, NaN => 0.0)
        surface_flux_values = replace(cache.elements.surface_flux_values, NaN => 0.0)
        @test surface_flux_values_gpu ≈ surface_flux_values

        # Test `cuda_prolong2boundaries!`
        TrixiGPU.cuda_prolong2boundaries!(u_gpu, mesh_gpu, boundary_conditions_gpu, equations_gpu,
                                          cache_gpu)
        Trixi.prolong2boundaries!(cache, u, mesh, equations, solver.surface_integral, solver)
        boundaries_u_gpu = replace(cache_gpu.boundaries.u, NaN => 0.0)
        boundaries_u = replace(cache.boundaries.u, NaN => 0.0)
        @test boundaries_u_gpu ≈ boundaries_u

        # Test `cuda_boundary_flux!`
        TrixiGPU.cuda_boundary_flux!(t_gpu, mesh_gpu, boundary_conditions_gpu,
                                     Trixi.have_nonconservative_terms(equations_gpu), equations_gpu,
                                     solver_gpu, cache_gpu)
        Trixi.calc_boundary_flux!(cache, t, boundary_conditions, mesh, equations,
                                  solver.surface_integral, solver)
        surface_flux_values_gpu = replace(cache_gpu.elements.surface_flux_values, NaN => 0.0)
        surface_flux_values = replace(cache.elements.surface_flux_values, NaN => 0.0)
        @test surface_flux_values_gpu ≈ surface_flux_values

        # Test `cuda_surface_integral!`
        TrixiGPU.cuda_surface_integral!(du_gpu, mesh_gpu, equations_gpu, solver_gpu, cache_gpu)
        Trixi.calc_surface_integral!(du, u, mesh, equations, solver.surface_integral, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_jacobian!`
        TrixiGPU.cuda_jacobian!(du_gpu, mesh_gpu, equations_gpu, cache_gpu)
        Trixi.apply_jacobian!(du, mesh, equations, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_sources!`
        TrixiGPU.cuda_sources!(du_gpu, u_gpu, t_gpu, source_terms_gpu, equations_gpu, cache_gpu)
        Trixi.calc_sources!(du, u, t, source_terms, equations, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Copy data back to host
        du_cpu, u_cpu = TrixiGPU.copy_to_host!(du_gpu, u_gpu)
    end

    @testset "Shallow Water 2D" begin
        equations = ShallowWaterEquations2D(gravity_constant = 9.81)

        initial_condition = initial_condition_convergence_test

        boundary_condition = BoundaryConditionDirichlet(initial_condition)

        volume_flux = (flux_wintermeyer_etal, flux_nonconservative_wintermeyer_etal)
        solver = DGSEM(polydeg = 3,
                       surface_flux = (flux_lax_friedrichs, flux_nonconservative_fjordholm_etal),
                       volume_integral = VolumeIntegralFluxDifferencing(volume_flux))

        coordinates_min = (0.0, 0.0)
        coordinates_max = (sqrt(2.0), sqrt(2.0))
        mesh = TreeMesh(coordinates_min, coordinates_max,
                        initial_refinement_level = 3,
                        n_cells_max = 10_000,
                        periodicity = false)

        semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver,
                                            boundary_conditions = boundary_condition,
                                            source_terms = source_terms_convergence_test)

        tspan = (0.0, 1.0)

        # Get CPU data
        (; mesh, equations, initial_condition, boundary_conditions, source_terms, solver, cache) = semi

        # Get GPU data
        equations_gpu = deepcopy(equations)
        mesh_gpu, solver_gpu, cache_gpu = deepcopy(mesh), deepcopy(solver), deepcopy(cache)
        boundary_conditions_gpu, source_terms_gpu = deepcopy(boundary_conditions),
                                                    deepcopy(source_terms)

        # Set initial time
        t = t_gpu = 0.0

        # Get initial data
        ode = semidiscretize(semi, tspan)
        u_ode = copy(ode.u0)
        du_ode = similar(u_ode)
        u = Trixi.wrap_array(u_ode, mesh, equations, solver, cache)
        du = Trixi.wrap_array(du_ode, mesh, equations, solver, cache)

        # Copy data to device
        du_gpu, u_gpu = TrixiGPU.copy_to_device!(du, u)
        # Reset data on host
        Trixi.reset_du!(du, solver, cache)

        # Test `cuda_volume_integral!`
        TrixiGPU.cuda_volume_integral!(du_gpu, u_gpu, mesh_gpu,
                                       Trixi.have_nonconservative_terms(equations_gpu),
                                       equations_gpu, solver_gpu.volume_integral, solver_gpu,
                                       cache_gpu)
        Trixi.calc_volume_integral!(du, u, mesh, Trixi.have_nonconservative_terms(equations),
                                    equations, solver.volume_integral, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_prolong2interfaces!`
        TrixiGPU.cuda_prolong2interfaces!(u_gpu, mesh_gpu, equations_gpu, cache_gpu)
        Trixi.prolong2interfaces!(cache, u, mesh, equations, solver.surface_integral, solver)
        interfaces_u_gpu = replace(cache_gpu.interfaces.u, NaN => 0.0)
        interfaces_u = replace(cache.interfaces.u, NaN => 0.0)
        @test interfaces_u_gpu ≈ interfaces_u

        # Test `cuda_interface_flux!`
        TrixiGPU.cuda_interface_flux!(mesh_gpu, Trixi.have_nonconservative_terms(equations_gpu),
                                      equations_gpu, solver_gpu, cache_gpu)
        Trixi.calc_interface_flux!(cache.elements.surface_flux_values, mesh,
                                   Trixi.have_nonconservative_terms(equations), equations,
                                   solver.surface_integral, solver, cache)
        surface_flux_values_gpu = replace(cache_gpu.elements.surface_flux_values, NaN => 0.0)
        surface_flux_values = replace(cache.elements.surface_flux_values, NaN => 0.0)
        @test surface_flux_values_gpu ≈ surface_flux_values

        # Test `cuda_prolong2boundaries!`
        TrixiGPU.cuda_prolong2boundaries!(u_gpu, mesh_gpu, boundary_conditions_gpu, equations_gpu,
                                          cache_gpu)
        Trixi.prolong2boundaries!(cache, u, mesh, equations, solver.surface_integral, solver)
        boundaries_u_gpu = replace(cache_gpu.boundaries.u, NaN => 0.0)
        boundaries_u = replace(cache.boundaries.u, NaN => 0.0)
        @test boundaries_u_gpu ≈ boundaries_u

        # Test `cuda_boundary_flux!`
        TrixiGPU.cuda_boundary_flux!(t_gpu, mesh_gpu, boundary_conditions_gpu,
                                     Trixi.have_nonconservative_terms(equations_gpu), equations_gpu,
                                     solver_gpu, cache_gpu)
        Trixi.calc_boundary_flux!(cache, t, boundary_conditions, mesh, equations,
                                  solver.surface_integral, solver)
        surface_flux_values_gpu = replace(cache_gpu.elements.surface_flux_values, NaN => 0.0)
        surface_flux_values = replace(cache.elements.surface_flux_values, NaN => 0.0)
        @test surface_flux_values_gpu ≈ surface_flux_values

        # Test `cuda_prolong2mortars!`
        TrixiGPU.cuda_prolong2mortars!(u_gpu, mesh_gpu, TrixiGPU.check_cache_mortars(cache_gpu),
                                       solver_gpu, cache_gpu)
        Trixi.prolong2mortars!(cache, u, mesh, equations,
                               solver.mortar, solver.surface_integral, solver)
        u_upper_gpu = replace(cache_gpu.mortars.u_upper, NaN => 0.0)
        u_lower_gpu = replace(cache_gpu.mortars.u_lower, NaN => 0.0)
        u_upper = replace(cache.mortars.u_upper, NaN => 0.0)
        u_lower = replace(cache.mortars.u_lower, NaN => 0.0)
        @test u_upper_gpu ≈ u_upper
        @test u_lower_gpu ≈ u_lower

        # Test `cuda_mortar_flux!`
        TrixiGPU.cuda_mortar_flux!(mesh_gpu, TrixiGPU.check_cache_mortars(cache_gpu),
                                   Trixi.have_nonconservative_terms(equations_gpu), equations_gpu,
                                   solver_gpu, cache_gpu)
        Trixi.calc_mortar_flux!(cache.elements.surface_flux_values, mesh,
                                Trixi.have_nonconservative_terms(equations), equations,
                                solver.mortar, solver.surface_integral, solver, cache)
        surface_flux_values_gpu = replace(cache_gpu.elements.surface_flux_values, NaN => 0.0)
        surface_flux_values = replace(cache.elements.surface_flux_values, NaN => 0.0)
        @test surface_flux_values_gpu ≈ surface_flux_values

        # Test `cuda_surface_integral!`
        TrixiGPU.cuda_surface_integral!(du_gpu, mesh_gpu, equations_gpu, solver_gpu, cache_gpu)
        Trixi.calc_surface_integral!(du, u, mesh, equations, solver.surface_integral, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_jacobian!`
        TrixiGPU.cuda_jacobian!(du_gpu, mesh_gpu, equations_gpu, cache_gpu)
        Trixi.apply_jacobian!(du, mesh, equations, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Test `cuda_sources!`
        TrixiGPU.cuda_sources!(du_gpu, u_gpu, t_gpu, source_terms_gpu, equations_gpu, cache_gpu)
        Trixi.calc_sources!(du, u, t, source_terms, equations, solver, cache)
        @test CUDA.@allowscalar du_gpu ≈ du

        # Copy data back to host
        du_cpu, u_cpu = TrixiGPU.copy_to_host!(du_gpu, u_gpu)
    end
end

end # module
