export ExplicitSolver, NewmarkSolver, AdaptiveSolver, StaticSolver

@doc raw"""
Central Difference explicit solver

- 'Δt': Float64,  time step size 
- 'globdat', GlobalData
- 'domain', Domain


Central Difference explicit solver for `M a + fint(u) = fext(u)`, with lumped mass matrix (MID = 0)
`a`, `v`, `u` are acceleration, velocity and displacement

```math
\begin{align}
u_{n+1} =& u_n + dtv_n + dt^2/2 a_n \\
v_{n+1} =& v_n + dt/2(a_n + a_{n+1}) \\
M a_{n+1} + f^{int}(u_{n+1}) =& f^{ext}_{n+1} \\
M a_{n+1} =& f^{ext}_{n+1} - f^{int}(u_{n+1}) \\
\end{align}
```

use the current states `a`, `v`, `u`, `time` in globdat, and update these stetes to next time step
update domain history 

todo
For the first time step
a_0 = M^{-1}(- f^{int}(u_0) + f^{ext}_0)

We assume globdat.acce[:] = a_0 and so far initialized to 0
"""->
function ExplicitSolver(Δt, globdat, domain)
    u = globdat.state[:]
    ∂u  = globdat.velo[:]
    ∂∂u = globdat.acce[:]

    fext = domain.fext
    
    ∂u += 0.5*Δt * ∂∂u
    u += Δt * ∂u
    
    domain.state[domain.eq_to_dof] = u[:]
    fint  = assembleInternalForce( globdat, domain, Δt)

    if length(globdat.M)==0
        error("globalDat is not initialized, call `assembleMassMatrix!(globaldat, domain)`")
    end

    ∂∂up = (fext - fint)./globdat.Mlumped
    ∂u += 0.5 * Δt * ∂∂up

    globdat.Dstate = globdat.state[:]
    globdat.state = u[:]
    globdat.velo = ∂u[:]
    globdat.acce = ∂∂up[:]

    globdat.time  += Δt

    #update strain, stress history 
    commitHistory(domain)
    #update state, acc history 
    updateStates!(domain, globdat)
    #update fint and fext history
    fint = assembleInternalForce( globdat, domain, Δt)
    push!(domain.history["fint"], fint)
    push!(domain.history["fext"], fext)
end





@doc raw"""
NewmarkSolver (Generalized-alpha) implicit solver
- 'Δt': Float64,  time step size 
- 'globdat', GlobalData
- 'domain', Domain
- 'αm', Float64
- 'αf', Float64 
- 'ε', Float64, absolute error for Newton convergence
- 'ε0', Float64, relative error for Newton convergence
-  'maxiterstep', Int64, maximum iteration number for Newton convergence
-  'η', Float64, Newton step size at the first iteration
- 'failsafe', Bool, if failsafe is true, when the Newton fails to converge, 
              revert back, and return false

Implicit solver for ``Ma  + fint(u) = fext``
``a``, ``v``, ``u`` are acceleration, velocity and displacement respectively.
```math
u_{n+1} = u_n + dtv_n + dt^2/2 ((1 - 2\beta)a_n + 2\beta a_{n+1})
v_{n+1} = v_n + dt((1 - \gamma)a_n + \gamma a_{n+1})
2\beta = 0.5*(1 - αm + αf)^2
\gamma = 0.5 - \alpha_m + \alpha_f

```

```math
a_{n+1-\alpha_m} = (1-\alpha_m)a_{n+1} + \alpha_m a_{n} 
v_{n+1-\alpha_f} = (1-\alpha_f)v_{n+1} + \alpha_f v_{n}
u_{n+1-\alpha_f} = (1-\alpha_f)u_{n+1} + \alpha_f u_{n}
M a_{n+1-\alpha_m} + f^{int}(u_{n+1-\alpha_f}) = f^{ext}_{n+1-\alpha_f}
```

'a_{n+1}' is solved by 

```math
M ((1-\alpha_m)a_{n+1} + \alpha_m a_{n})  
+ f^{int}((1-\alpha_f)(u_n + dtv_n + dt^2/2 ((1 - 2\beta)a_n + 2\beta a_{n+1}))) + \alpha_f u_{n}) 
= f^{ext}_{n+1-\alpha_f}
```


As for '\alpha_m' and '\alpha_f'
```math
\alpha_m = (2\rho_{\infty} - 1)/(\rho_{\infty} + 1)
\alpha_f = \rho_{\infty}/(\rho_{\infty} + 1)
```
    
use the current states `a`, `v`, `u`, `time` in globdat, and update these stetes to next time step
update domain history, when failsafe is true, and Newton's solver fails, nothing will be changed.

todo
For the first time step
a_0 = M^{-1}(- f^{int}(u_0) + f^{ext}_0)

We assume globdat.acce[:] = a_0 and so far initialized to 0
We also assume the external force is conservative (it does not depend on the current deformation)
"""->
function NewmarkSolver(Δt, globdat, domain, αm = -1.0, αf = 0.0, ε = 1e-8, ε0 = 1e-8, maxiterstep=100, η = 1.0, failsafe = false)
    local res0
    
    β2 = 0.5*(1 - αm + αf)^2
    γ = 0.5 - αm + αf

    # compute solution at uⁿ⁺¹
    failsafe_time = copy(globdat.time)
    globdat.time  += (1 - αf)*Δt

    # domain.Dstate = uⁿ
    failsafe_Dstate = copy(domain.Dstate)
    failsafe_state = copy(domain.state)
    domain.Dstate = domain.state[:]


    updateDomainStateBoundary!(domain, globdat)
    M = globdat.M
    
    ∂∂u = globdat.acce[:] #∂∂uⁿ
    u = globdat.state[:]  #uⁿ
    ∂u  = globdat.velo[:] #∂uⁿ

    fext = similar(u)
    getExternalForce!(domain, globdat, fext)


    ∂∂up = ∂∂u[:]

    Newtoniterstep, Newtonconverge = 0, false

    norm0 = Inf

    while !Newtonconverge
        
        Newtoniterstep += 1
        
        domain.state[domain.eq_to_dof] = (1 - αf)*(u + Δt*∂u + 0.5 * Δt * Δt * ((1 - β2)*∂∂u + β2*∂∂up)) + αf*u
        fint, stiff = assembleStiffAndForce( globdat, domain, Δt)
        res = M * (∂∂up *(1 - αm) + αm*∂∂u)  + fint - fext
        if Newtoniterstep==1
            res0 = res 
        end
        A = M*(1 - αm) + (1 - αf) * 0.5 * β2 * Δt^2 * stiff
        Δ∂∂u = A\res


        while η * norm(Δ∂∂u) > norm0
            η /= 2.0
            @info "η", η
        end
        ∂∂up -= η*Δ∂∂u


        println("$Newtoniterstep/$maxiterstep, $(norm(res))")
        if (norm(res)< ε || norm(res)< ε0*norm(res0) ||Newtoniterstep > maxiterstep)
            if Newtoniterstep > maxiterstep
                # Newton method does not converge
                if failsafe 
                    globdat.time = failsafe_time
                    domain.state = failsafe_state[:]
                    domain.Dstate = failsafe_Dstate[:]
                    return false 
                end
                # When failsafe is not on, test the gradient 
                function f(∂∂up)
                    domain.state[domain.eq_to_dof] = (1 - αf)*(u + Δt*∂u + 0.5 * Δt * Δt * ((1 - β2)*∂∂u + β2*∂∂up)) + αf*u
                    fint, stiff = assembleStiffAndForce( globdat, domain )
                    fint, (1 - αf) * 0.5 * β2 * Δt^2 * stiff
                end
                gradtest(f, ∂∂up)
                @warn("Newton iteration cannot converge $(norm(res))"); Newtonconverge = true
            else
                Newtonconverge = true
                printstyled("[Newmark] Newton converged $Newtoniterstep\n", color=:green)
            end
        end

        η = min(1.0, 2η)
        norm0 = norm(Δ∂∂u)
    end
    

    #update globdat to the next time step
    globdat.Dstate = globdat.state[:]
    globdat.state += Δt * ∂u + Δt^2/2 * ((1 - β2) * ∂∂u + β2 * ∂∂up)
    globdat.velo += Δt * ((1 - γ) * ∂∂u + γ * ∂∂up)
    globdat.acce = ∂∂up[:]
    globdat.time  += αf*Δt

    #commit history in domain
    commitHistory(domain)
    updateStates!(domain, globdat)
    fint, stiff = assembleStiffAndForce( globdat, domain, Δt)
    push!(domain.history["fint"], fint)
    push!(domain.history["fext"], fext)
    push!(domain.history["time"], [globdat.time])

    return true
    
end 


@doc raw"""
Static implicit solver
- 'globdat', GlobalData
- 'domain', Domain
- 'loaditerstep', Int64, load stepping steps
- 'ε', Float64, absolute error for Newton convergence
-  'maxiterstep', Int64, maximum iteration number for Newton convergence

Solver for ``fint(u) = fext`` with load stepping, ``u`` is the displacement.
Iteratively solve u_{i}
```math
f^{int}(u_i) = i/loaditerstep f^{ext}
```

todo
We assume the external force is conservative (it does not depend on the current deformation)

"""
function StaticSolver(globdat, domain, loaditerstep = 10, ε = 1.e-8, maxiterstep=100)
    
    fext = domain.fext
    globdat.Dstate = copy(globdat.state)
    for iterstep = 1:loaditerstep

        # Newton's method
        Newtoniterstep, Newtonconverge = 0, false
        
        while  !Newtonconverge

            Newtoniterstep += 1
            
            fint, stiff = assembleStiffAndForce( globdat, domain )
       
            res = fint - iterstep/loaditerstep * fext

            Δstate = stiff\res

            globdat.state -= Δstate
            #@show Newtoniterstep, norm(res)
            if (norm(res) < ε  || Newtoniterstep > maxiterstep)
                if Newtoniterstep > maxiterstep
                    @error "$Newtoniterstep Newton iteration cannot converge"
                end
                Newtonconverge = true
            end
            updateStates!(domain, globdat)
        end
        commitHistory(domain)
        globdat.Dstate = copy(globdat.state)
    end
end



@doc """
    Adaptive Solver, solve the whole process, if this step fails, redo the step with half of
    the time step size, when there are continuing 5 successful steps, double the step size when dt < T/NT

    - 'solvername': String,  so far only NewmarkSolver is supported
    - 'globdat', GlobalData
    - 'domain', Domain
    - 'T', Float64, total simulation time
    - 'NT', Int64, planned time steps
    - 'args', Dict{String, Value}, arguments for the solver

    
    return globdat, domain, ts, here ts is Float64[nteps+1] 

todo
For the first time step
a_0 = M^{-1}(- f^{int}(u_0) + f^{ext}_0)

We assume globdat.acce[:] = a_0 and so far initialized to 0
"""->
function AdaptiveSolver(solvername, globdat, domain, T, NT, args)

    failsafe = true
    ts = Float64[]

    Δt = T/NT #specified(maximum) time step
    dt = T/NT #current time step
    t = 0.0   #current time
    push!(ts, t)

    if solvername == "NewmarkSolver"
        ρ_oo = args["Newmark_rho"]
        η = args["damped_Newton_eta"]
        maxiterstep = args["Newton_maxiter"]
        ε = args["Newton_Abs_Err"]
        ε0 = args["Newton_Rel_Err"]
       

        αm = (2*ρ_oo - 1)/(ρ_oo + 1)
        αf = ρ_oo/(ρ_oo + 1)

        convergeCounter = 0
        while t < T
            if t + dt > T 
                dt = T - t
            end
            printstyled("dt = $dt, t = $t, T=$T\n", color=:cyan)
            
            convergeOrNot = NewmarkSolver(dt, globdat, domain, αm, αf, ε, ε0, maxiterstep, η, failsafe)
            
            if convergeOrNot
                convergeCounter += 1
                t += dt
                push!(ts, t)
                @assert globdat.time ≈ t
                #todo hardcode it to be 5
                if dt < 0.8*Δt  && convergeCounter >=5
                    dt = 2*dt
                end

            else
                @assert globdat.time ≈ t
                convergeCounter = 0
                dt /= 2.0

                @warn("Repeat time step with dt = ", dt)
            end
        end

    else
        @error("AdaptiveSolve has not implemented for ", solvername)
    end

    return globdat, domain, ts
    
end
    
    
