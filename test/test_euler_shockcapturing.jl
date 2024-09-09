
module TestCompressibleEulerShock # with `nonconservative_terms::False`

using Trixi, TrixiGPU
using OrdinaryDiffEq
using Test, CUDA

# Start testing with a clean environment
outdir = "out"
isdir(outdir) && rm(outdir, recursive = true)

# Test precision of the semidiscretization process
@testset "Test Compressible Euler" begin
    @testset "Compressible Euler 1D" begin
        equations = CompressibleEulerEquations1D(1.4)

        initial_condition = initial_condition_weak_blast_wave

        surface_flux = flux_lax_friedrichs
        volume_flux = flux_shima_etal
        basis = LobattoLegendreBasis(3)
        indicator_sc = IndicatorHennemannGassner(equations, basis,
                                                 alpha_max = 0.5,
                                                 alpha_min = 0.001,
                                                 alpha_smooth = true,
                                                 variable = density_pressure)
        volume_integral = VolumeIntegralShockCapturingHG(indicator_sc;
                                                         volume_flux_dg = volume_flux,
                                                         volume_flux_fv = surface_flux)
        solver = DGSEM(basis, surface_flux, volume_integral)

        coordinates_min = -2.0
        coordinates_max = 2.0
        mesh = TreeMesh(coordinates_min, coordinates_max,
                        initial_refinement_level = 5,
                        n_cells_max = 10_000)

        semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)

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

    @testset "Compressible Euler 2D" begin
        equations = CompressibleEulerEquations2D(1.4)

        initial_condition = initial_condition_weak_blast_wave

        surface_flux = flux_lax_friedrichs
        volume_flux = flux_shima_etal
        basis = LobattoLegendreBasis(3)
        indicator_sc = IndicatorHennemannGassner(equations, basis,
                                                 alpha_max = 0.5,
                                                 alpha_min = 0.001,
                                                 alpha_smooth = true,
                                                 variable = density_pressure)
        volume_integral = VolumeIntegralShockCapturingHG(indicator_sc;
                                                         volume_flux_dg = volume_flux,
                                                         volume_flux_fv = surface_flux)
        solver = DGSEM(basis, surface_flux, volume_integral)

        coordinates_min = (-2.0, -2.0)
        coordinates_max = (2.0, 2.0)
        mesh = TreeMesh(coordinates_min, coordinates_max,
                        initial_refinement_level = 5,
                        n_cells_max = 10_000)

        semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)

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

    @testset "Compressible Euler 3D" begin
        equations = CompressibleEulerEquations3D(1.4)

        initial_condition = initial_condition_weak_blast_wave

        surface_flux = flux_ranocha # OBS! Using a non-dissipative flux is only sensible to test EC,
        # but not for real shock simulations
        volume_flux = flux_ranocha
        polydeg = 3
        basis = LobattoLegendreBasis(polydeg)
        indicator_sc = IndicatorHennemannGassner(equations, basis,
                                                 alpha_max = 0.5,
                                                 alpha_min = 0.001,
                                                 alpha_smooth = true,
                                                 variable = density_pressure)
        volume_integral = VolumeIntegralShockCapturingHG(indicator_sc;
                                                         volume_flux_dg = volume_flux,
                                                         volume_flux_fv = surface_flux)
        solver = DGSEM(basis, surface_flux, volume_integral)

        coordinates_min = (-2.0, -2.0, -2.0)
        coordinates_max = (2.0, 2.0, 2.0)
        mesh = TreeMesh(coordinates_min, coordinates_max,
                        initial_refinement_level = 3,
                        n_cells_max = 100_000)

        semi = SemidiscretizationHyperbolic(mesh, equations, initial_condition, solver)

        tspan = (0.0, 0.4)

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
        u_upper_left_gpu = replace(cache_gpu.mortars.u_upper_left, NaN => 0.0)
        u_upper_right_gpu = replace(cache_gpu.mortars.u_upper_right, NaN => 0.0)
        u_lower_left_gpu = replace(cache_gpu.mortars.u_lower_left, NaN => 0.0)
        u_lower_right_gpu = replace(cache_gpu.mortars.u_lower_right, NaN => 0.0)
        u_upper_left = replace(cache.mortars.u_upper_left, NaN => 0.0)
        u_upper_right = replace(cache.mortars.u_upper_right, NaN => 0.0)
        u_lower_left = replace(cache.mortars.u_lower_left, NaN => 0.0)
        u_lower_right = replace(cache.mortars.u_lower_right, NaN => 0.0)
        @test u_upper_left_gpu ≈ u_upper_left
        @test u_upper_right_gpu ≈ u_upper_right
        @test u_lower_left_gpu ≈ u_lower_left
        @test u_lower_right_gpu ≈ u_lower_right

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
