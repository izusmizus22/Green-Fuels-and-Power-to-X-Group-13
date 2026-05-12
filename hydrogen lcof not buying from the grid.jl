
using JuMP
using HiGHS
using CSV         
using DataFrames  

function calculate_set_based_h2_lcof(;
    renewable_profile,            
    hours_in_year = 8760, 
    
    wind_lcoe_mwh = 45.0,         # Fixed LCOE for wind energy
    electrolyzer_cf = 0.5,        # 50% operating rate
    
    # --- BY-PRODUCT REVENUE (OXYGEN) ---
    mass_ratio_o2_h2 = 4.88,         # kg of O2 produced per kg of H2
    price_o2_per_kg = 0.15,       # https://www.imarcgroup.com/oxygen-pricing-report
    
    # --- SHIP BASELINE DEMAND INPUTS ---
    hfo_tonnes_yr = 29800.0,    
    hfo_lhv_gj_ton = 39.0,      
    h2_lhv_gj_ton = 120.0,      
    
    # --- ELECTROLYZER & STORAGE PARAMETERS ---      
    capex_per_mw = 650000.0,      #excel stuff
    fixed_om_per_mw = 13000.0,    
    efficiency_mwh_per_kg = 0.05, 
    lifetime_yrs = 25,            
    storage_capex_per_kg = 50.0,    
    discount_rate = 0.08          
)

    # ==========================================
    # STEP 0: CALCULATE DEMAND & PARAMETERS
    # ==========================================
    total_energy_gj_yr = hfo_tonnes_yr * hfo_lhv_gj_ton
    demand_kg_yr = (total_energy_gj_yr / h2_lhv_gj_ton) * 1000.0
    hourly_demand = demand_kg_yr / hours_in_year

    println("--- H2 System Parameters ---")
    println("Operating Rate:      ", electrolyzer_cf * 100, "%")
    println("Wind LCOE:           ", wind_lcoe_mwh, " €/MWh")
    println("H2 Demand:           ", round(demand_kg_yr, digits=2), " kg/year")
    println("O2 Selling Price:    ", price_o2_per_kg, " €/kg")
    println("----------------------------\n")

    # ==========================================
    # STEP 1. DEFINE SETS, VARIABLES AND SYSTEM PARAMETERS
    # ==========================================
    
    T = 1:hours_in_year
    Units = ["Electrolyzer", "Wind_offshore", "Grid_import", "H2_tank", "Ship_demand"]

    Elproduction = Dict("Electrolyzer" => 0.0, "Wind_offshore" => 1.0, "Grid_import" => 1.0, "H2_tank" => 0.0, "Ship_demand" => 0.0)
    Elconsumption = Dict("Electrolyzer" => efficiency_mwh_per_kg, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "Ship_demand" => 0.0)

    Load_min = Dict(u => 0.1 for u in Units) #https://pdf.sciencedirectassets.com/271472/1-s2.0-S0360319923X0113X/1-s2.0-S0360319923053405/main.pdf?X-Amz-Security-Token=IQoJb3JpZ2luX2VjEEgaCXVzLWVhc3QtMSJHMEUCIQChAERprYyTcT0IGPezCAaxgGBoNwVgg1Mw8htm5iMDIgIgJcwi3tquiWPYV4XJzMjL%2BzXVED2aessWn4NMM4ihJYkqswUIERAFGgwwNTkwMDM1NDY4NjUiDEcRe6RgMyyGdwSugiqQBa3vEqJoTUhYYFCldMZP28101cjK4tZKVyLyaKIM9dBMQjrCuOxcUvq%2B9yopJIg%2FJ5dHZ5kQli1wzQa1DqheQsl%2BCa%2F3ADOzTgDe4KnmlNfUCpFje5Gq1%2BzUQeKhdx7CLe27CVUU3Ofbf2ZwxK%2BosIvAf2fBlwWDLhvHtjhevVSdJbjBIviB6yRzseYOT9SoU7j8nzKLngiklIQMkwhQHLSZfuSJTpfow1My%2FhNVQiUcJ45jiztgXk2o8EA8xd0bYhVKM3Mkek17Diu9ig7uVTEBBCIbDyEajisoY9XqvnrdKnHAWbsGyOj8aRyVp5gELNg%2B7eAsxu5dwzWqZVUo0xnlaj5nvm8U6PgvpBvpEnZrDK3uy4pyLHeBnAQ47Tiq3ON2zKCPMNmXsfXDHthpsJJwbRaatlgDMiNUPKA9tZ2wlhwkAdoaiYF2spe4dvGX0yfEdX5I%2FgbBDRBnQGoiA7J0rIDJfTmLj2qydHZ%2BM6j%2B%2BQ1DqTagcUThkYN%2Fk8%2FAx6FDwvk5h4wgEc%2BvnDbFSHnggNPVANvYFkWzFkWLOxvMyk4wmR8r3RWa1FSgTxdqEw5Jdu491rZUWp41g1sM8gpPgc3nIR%2F%2Fa0MZRkesZRx6YwXxd2L9FJFQZfvR8%2FEFZeDpSh4%2FBBDAYLkTPLy5KK1mnlXesy5ayybx9CrSMVJd%2Fd3p6HEPsNbKI7U%2F2oqYVJlyqlG4msuxS8sBfywNaWlviGj%2BgQR%2BSZL%2BlHMv4%2BsgfgU%2FFXNXRInr4DuIzueRt203RTUza%2BuUs4oAnXEq1Wneft8WOubKFHBzKUr6tXOIUD7%2FirSE4RIccsifZClCKPf5znpNAPc0zJXUkQbfhrWKwHNZPH8z9Ky9a4sXd316MKv1zc8GOrEBu1aQXenLcx7GdggX7PTSDBzxxF7p0YMUstwVGoS8MnMH2JTPdurOrBBJt3OWrzHG5F%2FyaLPn1rxhluMJnwODFs0tfrlt81s2MgfyY0A1nZLN2bFmE8BdVXZlBJPZyB0cLdhZsITUzQn9LPYoVV0ZHU%2F350sLmKRnv%2BMefvJUdXH%2FMrnOcsbKs91Dcvkc%2FnZ4CGPvUaR6apAj2RhiKY0bZwTneV02phMm6DliiC4STdgy&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260430T163710Z&X-Amz-SignedHeaders=host&X-Amz-Expires=300&X-Amz-Credential=ASIAQ3PHCVTYXCD4ZA3O%2F20260430%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Signature=6d57eb65a19a9eaa66fea62423b49dd9eb017e44ea092fe33295324c0a5faf43&hash=59b20d659af2787fa3009d34204a4844226e867f3dcefdce1621bd717883abf4&host=68042c943591013ac2b2430a89b270f6af2c76d8dfd086a07176afe7c76c2c61&pii=S0360319923053405&tid=spdf-0feee037-ca0a-461b-8b2d-590563bd83a8&sid=5376431b778ee048174942b29a64fcd1a490gxrqb&type=client&tsoh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&rh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&ua=0a085d035357055c57&rr=9f47f8311dc311e7&cc=dk
    Load_max = Dict(u => 1.0 for u in Units)

    crf = (discount_rate * (1 + discount_rate)^lifetime_yrs) / ((1 + discount_rate)^lifetime_yrs - 1)
    
    Investment = Dict("Electrolyzer" => capex_per_mw * efficiency_mwh_per_kg, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => storage_capex_per_kg, "Ship_demand" => 0.0)
    Annuity_factor = Dict(u => crf for u in Units)
    Fixed_OM = Dict("Electrolyzer" => fixed_om_per_mw * efficiency_mwh_per_kg, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "Ship_demand" => 0.0)
    Variable_OM = Dict(u => 0.0 for u in Units) 
    
    # Fuel Cost (Costs)
    Fuel_cost = Dict(
        "Wind_offshore" => fill(wind_lcoe_mwh, hours_in_year), 
        "Grid_import" => fill(wind_lcoe_mwh + 20.0, hours_in_year), 
        "Electrolyzer" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "Ship_demand" => fill(0.0, hours_in_year)
    )

    # By-Product Price (Revenues)
    By_product_price = Dict(
        "Electrolyzer" => fill(price_o2_per_kg, hours_in_year), 
        "Wind_offshore" => fill(0.0, hours_in_year), 
        "Grid_import" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "Ship_demand" => fill(0.0, hours_in_year)
    )

    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    @variable(model, X[u in Units, t in T] >= 0) 
    @variable(model, B[u in Units, t in T] >= 0) 
    @variable(model, S[u in Units, t in T] >= 0) 
    @variable(model, Cap[u in Units] >= 0) 

    # ==========================================
    # STEP 2. OBJECTIVE FUNCTION 
    # ==========================================
    
    @objective(model, Min, 
        sum(Fuel_cost[u][t] * B[u, t] for u in Units, t in T) + 
        sum(Variable_OM[u] * X[u, t] for u in Units, t in T) + 
        sum(Fixed_OM[u] * Cap[u] for u in Units) + 
        sum(Investment[u] * Annuity_factor[u] * Cap[u] for u in Units) - 
        sum(By_product_price[u][t] * S[u, t] for u in Units, t in T) 
    )

    # ==========================================
    # STEP 3. SYSTEM CONSTRAINTS
    # ==========================================

    # --- FIXED CAPACITY CONSTRAINTS ---
    # We must force the capacity of the Ship Demand to exactly match our required hourly output
    @constraint(model, Cap["Ship_demand"] == hourly_demand)
    
    # Prevent the solver from building an infinite wind farm!
    @constraint(model, Cap["Wind_offshore"] <= 500.0)

    # NEW REQUEST: Unable to buy from the grid! Forcing Grid Import capacity to 0.
    @constraint(model, Cap["Grid_import"] == 0.0)

    @constraint(model, [t in T], B["Wind_offshore", t] == X["Wind_offshore", t])
    @constraint(model, [t in T], B["Grid_import", t] == X["Grid_import", t])
    @constraint(model, [u in ["Electrolyzer", "H2_tank", "Ship_demand"], t in T], B[u, t] == 0)

    # By-Product Generation Constraint
    @constraint(model, [t in T], S["Electrolyzer", t] == X["Electrolyzer", t] * mass_ratio_o2_h2)
    @constraint(model, [u in ["Wind_offshore", "Grid_import", "H2_tank", "Ship_demand"], t in T], S[u, t] == 0)

    # Capacity Factor Limit (50% Operating Rate limit)
    @constraint(model, sum(X["Electrolyzer", t] for t in T) <= electrolyzer_cf * Cap["Electrolyzer"] * hours_in_year)

    for t in T
        #Load constraints
        @constraint(model, Cap["Electrolyzer"] * Load_min["Electrolyzer"] <= X["Electrolyzer", t])
        @constraint(model, X["Electrolyzer", t] <= Cap["Electrolyzer"] * Load_max["Electrolyzer"])
        @constraint(model, Cap["H2_tank"] * Load_min["H2_tank"] <= X["H2_tank", t])
        @constraint(model, X["H2_tank", t] <= Cap["H2_tank"] * Load_max["H2_tank"])
        
        #Power available
        @constraint(model, X["Wind_offshore", t] <= Cap["Wind_offshore"] * renewable_profile[t])
        
        #Power balance
        @constraint(model, sum((Elproduction[u] - Elconsumption[u]) * X[u,t] for u in Units) == 0)
        
        #Storage balance+Mass balance
        if t == 1
            @constraint(model, X["H2_tank", 1] == X["H2_tank", hours_in_year] + X["Electrolyzer", 1] - X["Ship_demand", 1])
        else
            @constraint(model, X["H2_tank", t] == X["H2_tank", t-1] + X["Electrolyzer", t] - X["Ship_demand", t])
        end
        
        #Demand constraint
        @constraint(model, X["Ship_demand", t] == Cap["Ship_demand"])
    end
    
    # --- Solve ---
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL
        total_cost = objective_value(model)
        lcof = total_cost / demand_kg_yr
        
        o2_revenue = sum(value.(S["Electrolyzer", t]) * price_o2_per_kg for t in T)
        
        println("Optimization Successful!")
        println("OPTIMIZED Electrolyzer Size: ", round(value(Cap["Electrolyzer"]) * efficiency_mwh_per_kg, digits=2), " MW")
        println("OPTIMIZED H2 Tank Size:      ", round(value(Cap["H2_tank"]), digits=2), " kg")
        println("Oxygen By-Product Revenue:   € ", round(o2_revenue, digits=2))
        println("Total Annualized Cost:       € ", round(total_cost, digits=2), " (Net of O2 sales)")
        println("Levelized Cost of Fuel:      € ", round(lcof, digits=3), " / kg of Hydrogen")
        return lcof
    else
        println("Optimization failed. Status: ", termination_status(model))
        return nothing
    end
end

# ==========================================
# RUN THE OPTIMIZATION WITH 2024 WIND DATA
# ==========================================

# 1. Read the Renewables.ninja CSV file (Header is on row 5, separated by ';')
wind_df = CSV.read("ninja-wind-country-DK-current_offshore-merra2.csv", DataFrame, delim=";", header=5)

# 2. Filter exactly for the 2024 year
wind_2024 = filter(row -> startswith(string(row.time), "2024"), wind_df)

# 3. Extract the 'NATIONAL' wind capacity factor column as a normal Array
wind_profile_2024 = wind_2024.NATIONAL

# 2024 was a leap year, so it will have 8784 hours instead of 8760!
hours_2024 = length(wind_profile_2024) 

println("Loaded ", hours_2024, " hours of real wind data for 2024.")
println("Executing Capacity Expansion Optimization...")

# 4. Call the optimization model with the real wind profile!
calculate_set_based_h2_lcof(
    renewable_profile = wind_profile_2024,  
    hours_in_year = hours_2024
)