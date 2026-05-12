
using JuMP
using HiGHS
using CSV         
using DataFrames  

function calculate_set_based_ammonia_lcof(;
    hours_in_year = 8760, 
    renewable_profile, 
    
    # --- NEW: WIND LCOE & OPERATING RATE ---
    wind_lcoe_mwh = 45.0,         
    electrolyzer_cf = 0.5,        
    
    # --- NEW: BY-PRODUCT REVENUES (OXYGEN) ---
    mass_ratio_o2_h2 = 7.96,         # kg of O2 from Electrolyzer per kg of H2
    mass_ratio_o2_nh3 = 0.252,    # kg of O2 from Air Separation per kg of NH3
    price_o2_per_kg = 0.15,       
    
    # --- SHIP BASELINE DEMAND INPUTS ---
    hfo_tonnes_yr = 29800.0,      # HFO used annually by Tangier Maersk
    hfo_lhv_gj_ton = 39.0,        # Lower Heating Value of HFO
    nh3_lhv_gj_ton = 18.6,        # Lower Heating Value of Ammonia (Standard)
    
    # --- ELECTROLYZER (PEM) ---
    electrolyzer_mw = 200.0,      
    capex_per_mw_pem = 650000.0,  
    fixed_om_per_mw_pem = 13000.0,
    efficiency_mwh_per_kg_h2 = 0.05, 
    lifetime_yrs_pem = 25,        
    
    # --- AMMONIA SYNTHESIS PLANT (Haber-Bosch) ---
    h2_consumption_per_nh3 = 0.18, # 0.18 tonnes of H2 needed per ton of NH3
    capex_per_mw_nh3 = 1480000.0,  # 2030 DEA baseline (includes Air Separation Unit)
    fixed_om_per_mw_nh3 = 41390.0, # DEA baseline
    var_om_per_mwh_nh3 = 0.021,    # DEA baseline
    lifetime_yrs_nh3 = 30,         # Synthesis plants last longer than electrolyzers
    
    # --- HYDROGEN & AMMONIA STORAGE (Buffer) ---
    storage_capacity_kg = 100000.0, 
    storage_capex_per_kg = 50.0,    
    nh3_storage_capex_per_kg = 5.0, 
    
    # --- FINANCIALS ---
    discount_rate = 0.08          
)

    # ==========================================
    # STEP 0: CALCULATE EXACT AMMONIA & H2 DEMAND
    # ==========================================
    
    # 1. Total Energy Needed by Ship (GJ/year)
    total_energy_gj_yr = hfo_tonnes_yr * hfo_lhv_gj_ton
    
    # 2. Calculate Annual Ammonia Demand
    nh3_demand_tonnes_yr = total_energy_gj_yr / nh3_lhv_gj_ton
    nh3_demand_kg_yr = (nh3_demand_tonnes_yr * 1000.0)/0.9
    hourly_nh3_demand = nh3_demand_kg_yr / hours_in_year 
    
    # 3. Calculate Annual Hydrogen Demand for the Ammonia Plant
    h2_demand_kg_yr = nh3_demand_kg_yr * h2_consumption_per_nh3
    hourly_h2_demand = h2_demand_kg_yr / hours_in_year
    
    # 4. Calculate Ammonia Plant Size in MW (Output capacity)
    nh3_mwh_yr = (nh3_demand_kg_yr * (nh3_lhv_gj_ton / 3.6)) / 1000.0
    nh3_plant_mw = nh3_mwh_yr / hours_in_year
    
    println("--- Ship Energy & Ammonia Demand ---")
    println("Total Energy Needed:  ", total_energy_gj_yr, " GJ/year")
    println("Ammonia Demand (End): ", round(nh3_demand_kg_yr, digits=2), " kg/year")
    println("H2 Demand (Feed):     ", round(h2_demand_kg_yr, digits=2), " kg/year")
    println("NH3 Nominal Size:     ", round(nh3_plant_mw, digits=2), " MW")
    println("Operating Rate limits:", electrolyzer_cf * 100, "% (For both Electrolyzer & NH3 Plant)")
    println("Wind LCOE:            ", wind_lcoe_mwh, " €/MWh")
    println("O2 Selling Price:     ", price_o2_per_kg, " €/kg")
    println("------------------------------------\n")

    # ==========================================
    # STEP 1. DEFINE SETS, VARIABLES AND SYSTEM PARAMETERS 
    # ==========================================
    
    # Set of "time" [1:8760]
    T = 1:hours_in_year
    
    # NEW: Added "NH3_tank" to the system units
    Units = ["Electrolyzer", "Wind_offshore", "Grid_import", "H2_tank", "NH3_Plant", "NH3_tank", "Ship_demand"]
    
    # Power Balance / Mass Conversion Parameters
    Elproduction = Dict("Electrolyzer" => 0.0, "Wind_offshore" => 1.0, "Grid_import" => 1.0, "H2_tank" => 0.0, "NH3_Plant" => 0.0, "NH3_tank" => 0.0, "Ship_demand" => 0.0)
    Elconsumption = Dict("Electrolyzer" => efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "NH3_Plant" => 0.0, "NH3_tank" => 0.0, "Ship_demand" => 0.0)

    # Load constraints
    Load_min = Dict(u => 0.1 for u in Units) #sciencedirect.com/science/article/pii/S0360319925009139/pdfft?crasolve=1&r=9f47fc64fb8f11e7&ts=1777567202082&rtype=https&vrr=UKN&redir=UKN&redir_fr=UKN&redir_arc=UKN&vhash=UKN&host=d3d3LnNjaWVuY2VkaXJlY3QuY29t&tsoh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&rh=d3d3LnNjaWVuY2VkaXJlY3QuY29t&re=X2JsYW5rXw%3D%3D&ns_h=d3d3LnNjaWVuY2VkaXJlY3QuY29t&ns_e=X2JsYW5rXw%3D%3D&rh_fd=rrr)n%5Ed%60i%5E%60_dm%60%5Eo)%5Ejh&tsoh_fd=rrr)n%5Ed%60i%5E%60_dm%60%5Eo)%5Ejh&hc=~rrr)n%5Ed%60i%5E%60_dm%60%5Eo)%5Ejhwrrr)n%5Ed%60i%5E%60_dm%60%5Eo)%5Ejhwrrr)n%5Ed%60i%5E%60_dm%60%5Eo)%5Ejh&iv=9a1d1aea23083337202d350631438ccf&token=33323133616438303163633737336634656237626530646365333935623434343436353261653632376531303462643935383764336465323332616131323937346338343465336233373539623538336338383334363834326338336466653761346661373562353a643262393965613038393232633839646265326466636539&text=c55aa45195cab5e358a40e8d0688cf163188184d9b36c3ca2e118d544c6e689456cc7cf13c54194750700c9fc9942660e41b5af02fa33faca442597f015561c350658a7e79fc8459965caf54916a65c627cff80985a3937860d0281c8ba54320094e3f5f6cf6fa37a62351f336db95438ec9a0ec7cd1ec1b330cc7dc6289a030174197f1afec44756b17c96371c430cd1c6063dbb7b706d04c1d2e2867802870e5ad529aa2a18a0e7dffdd5e04fd8f095bbf1d70d7a12795d77462a1142fd65e8f005cad856d87c688e2c19112fa4f38da95258a1cfa391ca9f23b9794d5367cda7279a99f27d032d7f69373b816596dc7d3e68f3262b5f558204f13b71053afa697a63fdadefd76ed8dc676f1d1422bfe4120dbb117400388334a99378f4f6f2f0aa95cd30f93f6451bf081980084ac&original=3f6d64353d3362376331333666633930633232623938323661363564323838396538663237267069643d312d73322e302d53303336303331393932353030393133392d6d61696e2e706466&chkp=1c&rack=9f47fc64fb8f11e7
    Load_max = Dict(u => 1.0 for u in Units)
    
    # Only the Ship demand MUST run continuously (NH3 plant is now allowed to cycle)
    Load_min["Ship_demand"] = 1.0

    # Economic Parameters
    crf_pem = (discount_rate * (1 + discount_rate)^lifetime_yrs_pem) / ((1 + discount_rate)^lifetime_yrs_pem - 1)
    crf_nh3 = (discount_rate * (1 + discount_rate)^lifetime_yrs_nh3) / ((1 + discount_rate)^lifetime_yrs_nh3 - 1)
    
    Investment = Dict("Electrolyzer" => capex_per_mw_pem * efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => storage_capex_per_kg, "NH3_Plant" => capex_per_mw_nh3, "NH3_tank" => nh3_storage_capex_per_kg, "Ship_demand" => 0.0)
    Annuity_factor = Dict("Electrolyzer" => crf_pem, "Wind_offshore" => crf_pem, "Grid_import" => crf_pem, "H2_tank" => crf_pem, "NH3_Plant" => crf_nh3, "NH3_tank" => crf_nh3, "Ship_demand" => crf_pem)
    Fixed_OM = Dict("Electrolyzer" => fixed_om_per_mw_pem * efficiency_mwh_per_kg_h2, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "NH3_Plant" => fixed_om_per_mw_nh3, "NH3_tank" => 0.0, "Ship_demand" => 0.0)
    
    Variable_OM = Dict("Electrolyzer" => 0.0, "Wind_offshore" => 0.0, "Grid_import" => 0.0, "H2_tank" => 0.0, "NH3_Plant" => var_om_per_mwh_nh3, "NH3_tank" => 0.0, "Ship_demand" => 0.0)
    
    # Fuel Cost (Costs)
    Fuel_cost = Dict(
        "Wind_offshore" => fill(wind_lcoe_mwh, hours_in_year), 
        "Grid_import" => fill(wind_lcoe_mwh + 20.0, hours_in_year),
        "Electrolyzer" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "NH3_Plant" => fill(0.0, hours_in_year), 
        "NH3_tank" => fill(0.0, hours_in_year), 
        "Ship_demand" => fill(0.0, hours_in_year)
    )

    # By-Product Price (Revenues)
    By_product_price = Dict(
        "Electrolyzer" => fill(price_o2_per_kg, hours_in_year), 
        "Wind_offshore" => fill(0.0, hours_in_year), 
        "Grid_import" => fill(0.0, hours_in_year), 
        "H2_tank" => fill(0.0, hours_in_year), 
        "NH3_Plant" => fill(price_o2_per_kg, hours_in_year), 
        "NH3_tank" => fill(0.0, hours_in_year),
        "Ship_demand" => fill(0.0, hours_in_year)
    )

    # Initialize Optimization Problem
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    
    # --- DECISION VARIABLES ---
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
    @constraint(model, Cap["Ship_demand"] == hourly_nh3_demand)

    @constraint(model, [t in T], B["Wind_offshore", t] == X["Wind_offshore", t])
    @constraint(model, [t in T], B["Grid_import", t] == X["Grid_import", t])
    @constraint(model, [u in ["Electrolyzer", "H2_tank", "NH3_Plant", "NH3_tank", "Ship_demand"], t in T], B[u, t] == 0)

    # By-Product Generation Constraints
    @constraint(model, [t in T], S["Electrolyzer", t] == X["Electrolyzer", t] * mass_ratio_o2_h2)
    @constraint(model, [t in T], S["NH3_Plant", t] == X["NH3_Plant", t] * mass_ratio_o2_nh3)
    @constraint(model, [u in ["Wind_offshore", "Grid_import", "H2_tank", "NH3_tank", "Ship_demand"], t in T], S[u, t] == 0)

    # --- 50% OPERATING RATE LIMITS FOR ALL PLANTS ---
    @constraint(model, sum(X["Electrolyzer", t] for t in T) <= electrolyzer_cf * Cap["Electrolyzer"] * hours_in_year)
    @constraint(model, sum(X["NH3_Plant", t] for t in T) <= electrolyzer_cf * Cap["NH3_Plant"] * hours_in_year)

    # Mass conversion factors relative to the 100% baseline (from Step 0)
    h2_draw_per_mw = hourly_h2_demand / nh3_plant_mw
    nh3_prod_per_mw = hourly_nh3_demand / nh3_plant_mw

    for t in T
        # 1. Load constraints
        @constraint(model, Cap["Electrolyzer"] * Load_min["Electrolyzer"] <= X["Electrolyzer", t])
        @constraint(model, X["Electrolyzer", t] <= Cap["Electrolyzer"] * Load_max["Electrolyzer"])
        
        @constraint(model, Cap["H2_tank"] * Load_min["H2_tank"] <= X["H2_tank", t])
        @constraint(model, X["H2_tank", t] <= Cap["H2_tank"] * Load_max["H2_tank"])
        
        @constraint(model, Cap["NH3_Plant"] * Load_min["NH3_Plant"] <= X["NH3_Plant", t])
        @constraint(model, X["NH3_Plant", t] <= Cap["NH3_Plant"] * Load_max["NH3_Plant"])

        @constraint(model, Cap["NH3_tank"] * Load_min["NH3_tank"] <= X["NH3_tank", t])
        @constraint(model, X["NH3_tank", t] <= Cap["NH3_tank"] * Load_max["NH3_tank"])
        
        # 2. Power available from wind plant
        @constraint(model, X["Wind_offshore", t] <= Cap["Wind_offshore"] * renewable_profile[t])
        
        # 3. Power balance
        @constraint(model, sum((Elproduction[u] - Elconsumption[u]) * X[u,t] for u in Units) == 0)
        
        # 4. Storage balances (H2 and Ammonia)
        if t == 1
            @constraint(model, X["H2_tank", 1] == X["H2_tank", hours_in_year] + X["Electrolyzer", 1] - X["NH3_Plant", 1] * h2_draw_per_mw)
            @constraint(model, X["NH3_tank", 1] == X["NH3_tank", hours_in_year] + X["NH3_Plant", 1] * nh3_prod_per_mw - X["Ship_demand", 1])
        else
            @constraint(model, X["H2_tank", t] == X["H2_tank", t-1] + X["Electrolyzer", t] - X["NH3_Plant", t] * h2_draw_per_mw)
            @constraint(model, X["NH3_tank", t] == X["NH3_tank", t-1] + X["NH3_Plant", t] * nh3_prod_per_mw - X["Ship_demand", t])
        end
        
        # 5. Amount of fuel that has to be delivered to satisfy continuous demand
        @constraint(model, X["Ship_demand", t] == Cap["Ship_demand"])
    end
    
    # --- Solve ---
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL
        total_cost = objective_value(model)
        
        # LCOF is divided by the AMMONIA demand kg
        lcof_nh3 = total_cost / nh3_demand_kg_yr
        
        # Calculate how much total revenue was made from selling Oxygen from BOTH sources
        o2_revenue = sum(value.(S["Electrolyzer", t]) * price_o2_per_kg + value.(S["NH3_Plant", t]) * price_o2_per_kg for t in T)
        
        println("Optimization Successful!")
        println("OPTIMIZED Electrolyzer Size: ", round(value(Cap["Electrolyzer"]) * efficiency_mwh_per_kg_h2, digits=2), " MW")
        println("OPTIMIZED NH3 Plant Size:    ", round(value(Cap["NH3_Plant"]), digits=2), " MW")
        println("OPTIMIZED Wind Farm Size:    ", round(value(Cap["Wind_offshore"]), digits=2), " MW")
        println("OPTIMIZED H2 Tank Size:      ", round(value(Cap["H2_tank"]), digits=2), " kg")
        println("OPTIMIZED NH3 Tank Size:     ", round(value(Cap["NH3_tank"]), digits=2), " kg")
        println("Oxygen By-Product Revenue:   € ", round(o2_revenue, digits=2))
        println("Total Annualized Cost:       € ", round(total_cost, digits=2), " (Net of O2 sales)")
        println("Levelized Cost of Fuel:      € ", round(lcof_nh3, digits=3), " / kg of Ammonia")
        return lcof_nh3
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
# (We convert the time column to a string to safely check if it starts with "2024")
wind_2024 = filter(row -> startswith(string(row.time), "2024"), wind_df)

# 3. Extract the 'NATIONAL' wind capacity factor column as a normal Array
wind_profile_2024 = wind_2024.NATIONAL

# 2024 was a leap year, so it will have 8784 hours instead of 8760!
hours_2024 = length(wind_profile_2024) 

println("Loaded ", hours_2024, " hours of real wind data for 2024.")
println("Executing Capacity Expansion Optimization...")

# 4. Call the optimization model with the real wind profile!
calculate_set_based_ammonia_lcof(
    hours_in_year = hours_2024, 
    renewable_profile = wind_profile_2024
)