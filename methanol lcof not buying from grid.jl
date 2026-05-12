
using JuMP
using HiGHS
using CSV         
using DataFrames  

function calculate_set_based_methanol_lcof(;
    hours_in_year = 8760, 
    renewable_profile, 
    
    # --- NEW: WIND LCOE, OPERATING RATE & BY-PRODUCT ---
    wind_lcoe_mwh = 45.0,           # Fixed LCOE for wind energy
    electrolyzer_cf = 0.5,          # 50% operating rate
    mass_ratio_o2_h2 = 7.8,           # kg of O2 from Electrolyzer per kg of H2
    price_o2_per_kg = 0.15,         # selling price (EUR/kg)
    
    # --- SHIP BASELINE DEMAND INPUTS ---
    hfo_tonnes_yr = 29800.0,      # HFO used annually by Tangier Maersk
    hfo_lhv_gj_ton = 39.0,        # Lower Heating Value of HFO
    meoh_lhv_gj_ton = 19.9,       # Lower Heating Value of Methanol
    
    # --- ELECTROLYZER (PEM 2030) ---
    capex_per_mw_pem = 650000.0,  
    fixed_om_per_mw_pem = 13000.0,
    efficiency_mwh_per_kg_h2 = 0.05, 
    lifetime_yrs_pem = 25,        
    
    # --- METHANOL SYNTHESIS & CARBON CAPTURE ---
    h2_consumption_per_meoh = 0.19, # 0.19 tonnes of H2 needed per ton of MeOH
    cc_and_synthesis_mw = 11.0,    # excel
    capex_per_mw_meoh = 850000.0,   
    fixed_om_per_mw_meoh = 35000.0, 
    lifetime_yrs_meoh = 25,         
    
    # --- EXCESS HEAT & COMPRESSORS ---
    scenario = "reboiler",          # Scenarios
    compressor_mw = 2.0,            # Work done by the compressors directly (MW)
    excess_heat_mw = 10.0,          # Total excess heat available from the synthesis process (MW)
    efficiency_reboiler = 0.15,     # Efficiency for converting heat to electricity via reboilers
    efficiency_heat_pump = 0.05,    # Efficiency for converting heat to electricity via heat pumps
    working_factor = 0.50,          # "50% working" factor
    
    # --- HYDROGEN & METHANOL STORAGE (Buffer) ---
    storage_capex_per_kg = 50.0,    
    meoh_storage_capex_per_kg = 5.0, 
    
    # --- FINANCIALS ---
    discount_rate = 0.08          
)

    # ==========================================
    # STEP 0: CALCULATE EXACT METHANOL & H2 DEMAND
    # ==========================================
    
    # 1. Total Energy Needed by Ship (GJ/year)
    total_energy_gj_yr = hfo_tonnes_yr * hfo_lhv_gj_ton
    
    # 2. Calculate Annual Methanol Demand
    meoh_demand_tonnes_yr = total_energy_gj_yr / meoh_lhv_gj_ton
    meoh_demand_kg_yr = meoh_demand_tonnes_yr * 1000.0
    hourly_meoh_demand = meoh_demand_kg_yr / hours_in_year
    
    # 3. Calculate Annual Hydrogen Demand for the Methanol Plant
    h2_demand_kg_yr = meoh_demand_kg_yr * h2_consumption_per_meoh
    hourly_h2_demand = h2_demand_kg_yr / hours_in_year
    
    # 4. Calculate MeOH Plant Size in MW (Output capacity)
    meoh_mwh_yr = (meoh_demand_kg_yr * (meoh_lhv_gj_ton / 3.6)) / 1000.0
    meoh_plant_mw = meoh_mwh_yr / hours_in_year
    
    # 5. --- CALCULATE EXCESS HEAT RECOVERY & COMPRESSORS ---
    recovery_efficiency = scenario == "reboiler" ? efficiency_reboiler : efficiency_heat_pump
    
    # Calculate how much electricity we get back from the excess heat
    recovered_electricity_mw = excess_heat_mw * working_factor * recovery_efficiency
    
    # Net Methanol Plant Electricity Demand: CC & Synthesis + Compressors - Recovered Electricity
    net_meoh_el_mw = cc_and_synthesis_mw + compressor_mw - recovered_electricity_mw
    
    # Print out the calculated demand & scenarios to verify in the console
    println("--- Ship Energy & Methanol Demand ---")
    println("Total Energy Needed:   ", total_energy_gj_yr, " GJ/year")
    println("Methanol Demand (End): ", round(meoh_demand_kg_yr, digits=2), " kg/year")
    println("H2 Demand (Feed):      ", round(h2_demand_kg_yr, digits=2), " kg/year")
    println("MeOH Nominal Size:     ", round(meoh_plant_mw, digits=2), " MW")
    println("Operating Rate limits: ", electrolyzer_cf * 100, "% (For both Electrolyzer & MeOH Plant)")
    println("Wind LCOE:             ", wind_lcoe_mwh, " €/MWh")
    println("O2 Selling Price:      ", price_o2_per_kg, " €/kg")
    println("-------------------------------------")
    println("--- Heat Recovery Scenario: ", uppercase(scenario), " ---")
    println("CC & Synth Baseload:   ", cc_and_synthesis_mw, " MW")
    println("Compressor Work Added: ", compressor_mw, " MW")
    println("Excess Heat Available: ", excess_heat_mw, " MW")
    println("Working Factor:        ", working_factor * 100, "%")
    println("Conversion Efficiency: ", recovery_efficiency * 100, "%")
    println("Recovered Electricity: ", recovered_electricity_mw, " MW")
    println("Net MeOH Plant Demand: ", net_meoh_el_mw, " MW (constant)")
    println("-------------------------------------\n")


    # ==========================================
    # STEP 1. DEFINE SETS, VARIABLES AND SYSTEM PARAMETERS
    # ==========================================
    
    T = 1:hours_in_year
    Units = ["Electrolyzer", "Wind_offshore", "Grid_import", "H2_tank", "MeOH_Plant", "MeOH_tank", "Ship_demand"]

    Elproduction = Dict("Electrolyzer" => 0.0, "Wind_offshore" => 1.0, "Grid_import" => 1.0, "H2_tank" => 0.0, "MeOH_Plant" => 0.0, "MeOH_tank" => 0.0, "Ship_demand" => 0.0)
    
    # Specific electricity consumption per MW of Methanol capacity
    Elconsumption = Dict("Electrolyzer" => efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "MeOH_Plant" => (net_meoh_el_mw / meoh_plant_mw), "MeOH_tank" => 0.0, "Ship_demand" => 0.0)

    # -----------------------------------------------------
    # NEW: IMPLEMENTED MINIMUM LOAD LIMITS
    # -----------------------------------------------------
    Load_min = Dict(u => 0.0 for u in Units)
    Load_max = Dict(u => 1.0 for u in Units)
    
    Load_min["Electrolyzer"] = 0.10 # 10% min load
    Load_min["MeOH_Plant"] = 0.30   # 30% min load https://pdf.sciencedirectassets.com/271429/1-s2.0-S0306261926X00022/1-s2.0-S0306261926000814/main.pdf?X-Amz-Security-Token=IQoJb3JpZ2luX2VjEF0aCXVzLWVhc3QtMSJHMEUCIQD5B4HJiFuVVZYalSjdCR8HGGzXPkrzAG9k3QMJaTF5YAIgF6mhk8VXjGFxhkNbOElgveMM07aUI%2FahJP6EOTjd2HkqswUIJhAFGgwwNTkwMDM1NDY4NjUiDG1eWgZDMGELMLVmCiqQBUseTqNiuG%2B0JIbzTMYl4GKxTdBqJbieRO5W3IxJ98a9xOwhzFyL1McZF7a6ZqLDNAkp81tlQCT%2FVgAYWrxZRYHck5H2wsNd6%2BqU1%2BAujW2Q7nFzpQAhdmZc1i7cg1tJ9hP4QZg55O%2BWtZ0rhe0oc8Pdzr%2BoG2iXq%2FP7SKDgT1%2B35KVpOXtel5ycsBy%2FCd7kb3d%2FEsD9jP36sy6cLqpYR8Gt%2F2B7LM6uS9YnP%2FYW9TJT5LYAzgXwrntuYqH5K1jyfYC4UJAaP6igOvvtVrHjJeD9eswQkB73QXSgHPeI3iirbXOjLEc47xm6ANLN4hxfUx%2FuGBY9ymo%2F71l22wtk9xODlpPgwzLgH2fm4%2BGSXn2hl7UGyzkw1i51dQCuImSLb2zL57%2FvBXqkyBYmnuv%2BFk4mk9d1CsPhi0DihRYvUY1zv4zRZsCUXpmDSp29A2vHkI1l2lDNGSxBHf62ugCcMIgDYDCZOtJQSePizAMCEtxXGQpxiu2U%2BWdaiSH7XWFvPrTz%2BvwQ01%2FcaVo7DSKNIlASJaWSF1pmGD%2BxJbydjFM7HR88CDQZBypvcf6TFOXs70w%2FTN6ZcKFFEZfwgwJxdpiil3KQQxaNArAABv8hnBQwI%2BBzNPsj4Z6EFBpJsu7%2B8rlpPHT8qvPJFxhENobst8xFAuoOZMWd31npe5cAGV3kPVXkWZe2fabKZbTdYDFxr06R1oA7dEzXzToW8icS6qaliPOR6DeC2uJfgbrc014mIB7KtH84Efz4CsMOxs728zbEn6S6bON8%2Bv525sDaHo6lVZqT%2FaRmX6NTZD6vDPwiQ8m7hoTYo0E3%2F9WEiHFdUimTKw8IByfTWuPx2nGTj6Lu2eT7V9JYn7vzcW2zUWbqMKC60s8GOrEBd7nbzMGTPAio4j5DJnh%2B3B3D9NCGQ8p9niue34N9py2FeSLOBlwPg3GhzTKtpUkx8xqR%2B0DOpdKLDvvORORch8cM8lOBZCUtK9%2BYbTylf6Xy2Wz23x6%2Fh%2B1FKW0%2Fe5caBpMoSzxTCOIzbGwvf8EWnQxOWhZNuKk7w3K6FR%2Fef2HIhCA2eND6ugGJp1X8aoXpzgads6sPalySSkt6c1ahH1eQ2zVGRE0jVBXLRZqyUMs0&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=20260501T132403Z&X-Amz-SignedHeaders=host&X-Amz-Expires=300&X-Amz-Credential=ASIAQ3PHCVTYU7ZBDLPQ%2F20260501%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Signature=a2796e07a6fc63dfe73f57ac0ea17667cd3a7f1133c7f138482eed1295328257&hash=0686834259795df2ffb86de90de0a211105c2acc3657f1d4e0c2b514a4fccd78&host=68042c943591013ac2b2430a89b270f6af2c76d8dfd086a07176afe7c76c2c61&pii=S0306261926000814&tid=spdf-51154cf4-29c2-4345-ba46-fdd7ffbfc9d5&sid=5376431b778ee048174942b29a64fcd1a490gxrqb&type=client&tsoh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&rh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&ua=0a085d035306520506&rr=9f4f1ab0486b262e&cc=dk
    Load_min["Ship_demand"] = 1.0   # Only the ship demand must run continuously

    crf_pem = (discount_rate * (1 + discount_rate)^lifetime_yrs_pem) / ((1 + discount_rate)^lifetime_yrs_pem - 1)
    crf_meoh = (discount_rate * (1 + discount_rate)^lifetime_yrs_meoh) / ((1 + discount_rate)^lifetime_yrs_meoh - 1)
    
    Investment = Dict("Electrolyzer" => capex_per_mw_pem * efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => storage_capex_per_kg, "MeOH_Plant" => capex_per_mw_meoh, "MeOH_tank" => meoh_storage_capex_per_kg, "Ship_demand" => 0.0)
    Annuity_factor = Dict("Electrolyzer" => crf_pem, "Wind_offshore" => crf_pem, "Grid_import" => crf_pem, "H2_tank" => crf_pem, "MeOH_Plant" => crf_meoh, "MeOH_tank" => crf_meoh, "Ship_demand" => crf_pem)
    Fixed_OM = Dict("Electrolyzer" => fixed_om_per_mw_pem * efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "MeOH_Plant" => fixed_om_per_mw_meoh, "MeOH_tank" => 0.0, "Ship_demand" => 0.0)
    Variable_OM = Dict(u => 0.0 for u in Units) 
    
    # Fuel Cost (Costs) using Wind LCOE
    Fuel_cost = Dict(
        "Wind_offshore" => fill(wind_lcoe_mwh, hours_in_year), 
        "Grid_import" => fill(wind_lcoe_mwh + 20.0, hours_in_year), 
        "Electrolyzer" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "MeOH_Plant" => fill(0.0, hours_in_year), 
        "MeOH_tank" => fill(0.0, hours_in_year), 
        "Ship_demand" => fill(0.0, hours_in_year)
    )

    # By-Product Price (Revenues)
    By_product_price = Dict(
        "Electrolyzer" => fill(price_o2_per_kg, hours_in_year), 
        "Wind_offshore" => fill(0.0, hours_in_year), 
        "Grid_import" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "MeOH_Plant" => fill(0.0, hours_in_year), 
        "MeOH_tank" => fill(0.0, hours_in_year),
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

    # --- FIXED & REMOVED CAPACITIES ---
    @constraint(model, Cap["Grid_import"] == 0.0)         # NO GRID CONNECTION
    @constraint(model, Cap["Wind_offshore"] <= 500.0)     # 500 MW WIND LIMIT
    @constraint(model, Cap["Ship_demand"] == hourly_meoh_demand)

    @constraint(model, [t in T], B["Wind_offshore", t] == X["Wind_offshore", t])
    @constraint(model, [t in T], B["Grid_import", t] == X["Grid_import", t])
    @constraint(model, [u in ["Electrolyzer", "H2_tank", "MeOH_Plant", "MeOH_tank", "Ship_demand"], t in T], B[u, t] == 0)

    # By-Product Generation Constraints (O2 from Electrolyzer)
    @constraint(model, [t in T], S["Electrolyzer", t] == X["Electrolyzer", t] * mass_ratio_o2_h2)
    @constraint(model, [u in ["Wind_offshore", "Grid_import", "H2_tank", "MeOH_Plant", "MeOH_tank", "Ship_demand"], t in T], S[u, t] == 0)

    # --- 50% OPERATING RATE LIMITS FOR ALL PLANTS ---
    @constraint(model, sum(X["Electrolyzer", t] for t in T) <= electrolyzer_cf * Cap["Electrolyzer"] * hours_in_year)
    @constraint(model, sum(X["MeOH_Plant", t] for t in T) <= electrolyzer_cf * Cap["MeOH_Plant"] * hours_in_year)

    # Mass conversion factors relative to the 100% baseline (from Step 0)
    h2_draw_per_mw = hourly_h2_demand / meoh_plant_mw
    meoh_prod_per_mw = hourly_meoh_demand / meoh_plant_mw

    for t in T
        # 1. Load constraints
        @constraint(model, Cap["Electrolyzer"] * Load_min["Electrolyzer"] <= X["Electrolyzer", t])
        @constraint(model, X["Electrolyzer", t] <= Cap["Electrolyzer"] * Load_max["Electrolyzer"])
        
        @constraint(model, Cap["H2_tank"] * Load_min["H2_tank"] <= X["H2_tank", t])
        @constraint(model, X["H2_tank", t] <= Cap["H2_tank"] * Load_max["H2_tank"])
        
        @constraint(model, Cap["MeOH_Plant"] * Load_min["MeOH_Plant"] <= X["MeOH_Plant", t])
        @constraint(model, X["MeOH_Plant", t] <= Cap["MeOH_Plant"] * Load_max["MeOH_Plant"])

        @constraint(model, Cap["MeOH_tank"] * Load_min["MeOH_tank"] <= X["MeOH_tank", t])
        @constraint(model, X["MeOH_tank", t] <= Cap["MeOH_tank"] * Load_max["MeOH_tank"])
        
        # 2. Power available from wind plant
        @constraint(model, X["Wind_offshore", t] <= Cap["Wind_offshore"] * renewable_profile[t])
        
        # 3. Power balance
        @constraint(model, sum((Elproduction[u] - Elconsumption[u]) * X[u,t] for u in Units) == 0)
        
        # 4. Storage balances (H2 and Methanol)
        if t == 1
            @constraint(model, X["H2_tank", 1] == X["H2_tank", hours_in_year] + X["Electrolyzer", 1] - X["MeOH_Plant", 1] * h2_draw_per_mw)
            @constraint(model, X["MeOH_tank", 1] == X["MeOH_tank", hours_in_year] + X["MeOH_Plant", 1] * meoh_prod_per_mw - X["Ship_demand", 1])
        else
            @constraint(model, X["H2_tank", t] == X["H2_tank", t-1] + X["Electrolyzer", t] - X["MeOH_Plant", t] * h2_draw_per_mw)
            @constraint(model, X["MeOH_tank", t] == X["MeOH_tank", t-1] + X["MeOH_Plant", t] * meoh_prod_per_mw - X["Ship_demand", t])
        end
        
        # 5. Amount of fuel that has to be delivered to satisfy continuous demand
        @constraint(model, X["Ship_demand", t] == Cap["Ship_demand"])
    end
    
    # --- Solve ---
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL
        total_cost = objective_value(model)
        lcof_meoh = total_cost / meoh_demand_kg_yr
        
        # -----------------------------------------------------
        # NEW: EURO / GJ CALCULATION FOR APPLES-TO-APPLES COMPARISON
        # -----------------------------------------------------
        lcof_per_gj = total_cost / total_energy_gj_yr
        
        o2_revenue = sum(value.(S["Electrolyzer", t]) * price_o2_per_kg for t in T)
        
        println("Optimization Successful!")
        println("OPTIMIZED Electrolyzer Size: ", round(value(Cap["Electrolyzer"]) * efficiency_mwh_per_kg_h2, digits=2), " MW")
        println("OPTIMIZED MeOH Plant Size:   ", round(value(Cap["MeOH_Plant"]), digits=2), " MW")
        println("OPTIMIZED Wind Farm Size:    ", round(value(Cap["Wind_offshore"]), digits=2), " MW")
        println("OPTIMIZED H2 Tank Size:      ", round(value(Cap["H2_tank"]), digits=2), " kg")
        println("OPTIMIZED MeOH Tank Size:    ", round(value(Cap["MeOH_tank"]), digits=2), " kg")
        println("Oxygen By-Product Revenue:   € ", round(o2_revenue, digits=2))
        println("Total Annualized Cost:       € ", round(total_cost, digits=2), " (Net of O2 sales)")
        println("Levelized Cost of Fuel:      € ", round(lcof_meoh, digits=3), " / kg of Methanol")
        println("Levelized Cost of Energy:    € ", round(lcof_per_gj, digits=2), " / GJ") # <-- THE TRUE COMPARISON METRIC
        
        return lcof_per_gj
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
calculate_set_based_methanol_lcof(
    hours_in_year = hours_2024, 
    renewable_profile = wind_profile_2024,
    scenario = "reboiler"
)