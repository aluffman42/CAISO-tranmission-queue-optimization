using CSV, JuMP, Gurobi, DataFrames, Plots, FileIO, Measures
### Import the data

## solar and wind capacity factor

load_8760_path = "191_data_8760_from_kmeansv2.csv"
load_8760 = CSV.read(load_8760_path, DataFrame)
solar_cf = load_8760[:, 4]
wind_cf = load_8760[:, 5]
load_increase = load_8760[:, 3]


## population at each bus
bus_path = "fullstations.csv"
bus_df = CSV.read(bus_path, DataFrame)
bus_idx = bus_df[:, 1]
bus_avail = Dict(bus_df.IDX[i] => bus_df.Availability[i] for i in 1:nrow(bus_df))

##### BUS UPGRADE DICTIONARIES FOR ANDERS
bus_upgrade = Dict(bus_df.IDX[i] => bus_df.Constraint_original[i] for i in 1:nrow(bus_df))

# Remove duplicate constraints, keeping the first occurrence
unique_constraints = unique(bus_df, :Constraint_original)

# Create mapping from index to to (Constraint, Cost, Inc) using only unique constraints
constraint_to_cost_inc = Dict(
    i => (row.Constraint_original, row.Cost, row.Inc) for (i, row) in pairs(eachrow(unique_constraints))
)

# Update bus_upgrade: keys are bus IDX, values are the row index in unique_constraints (i.e., the key in constraint_to_cost_inc)
# NOTE that bus IDX starts at 0
bus_upgrade = Dict()
for (row_idx, row) in enumerate(eachrow(bus_df))
    # Find the row index in unique_constraints with the same Constraint_original
    constraint_idx = findfirst(x -> x.Constraint_original == row.Constraint_original, eachrow(unique_constraints))
    bus_upgrade[row.IDX] = constraint_idx
end


# solar queue
solar_path = "solar.csv"
solar_data = CSV.read(solar_path, DataFrame)
solar_capacity = solar_data[:, 2]
solar_buses = solar_data[:, 4]
solar_proj_cost = solar_data[:, 3]
solar_names = solar_data[:, 1]

# wind queue
wind_path = "wind.csv"
wind_data = CSV.read(wind_path, DataFrame)
wind_capacity = wind_data[:, 2]
wind_buses = wind_data[:, 4]
wind_proj_cost = wind_data[:, 3]
wind_names = wind_data[:, 1]

# gas queue
gas_path = "gas.csv"
gas_data = CSV.read(gas_path, DataFrame)
gas_capacity = gas_data[:, 2]
gas_buses = gas_data[:, 4]
gas_proj_cost = gas_data[:, 3]
gas_names = gas_data[:, 1]

### battery queue
battery_path = "batt.csv"
batt_data = CSV.read(battery_path, DataFrame)
batt_capacity = batt_data[:,2]
batt_storage = batt_data[:, 3]
batt_buses = batt_data[:, 5]
batt_proj_cost = batt_data[:, 4]
batt_names = batt_data[:, 1]

#### Constants
curtail_cost = 10000           # $/MWh
emissions_cost = 55        # $/ton
gas_emissions = 0.20196     # ton/MWh
η_rt = 0.86
η_ch = sqrt(η_rt)  
η_dis = sqrt(η_rt) 
inital_soc = 0.5 
final_soc = 0.5
wear_cost = 200.0      # $ per MWh

Nconstraints = length(constraint_to_cost_inc)
Nbuses = length(bus_idx)
Nsolar = length(solar_buses)
Nwind = length(wind_buses)
Ngas = length(gas_buses)
Nbatt = length(batt_buses)

steps = 8760

#### Model
m = Model(Gurobi.Optimizer)

# Binary project build decisions
@variable(m, solar_build[1:Nsolar], Bin)
@variable(m, wind_build[1:Nwind], Bin)
@variable(m, gas_build[1:Ngas], Bin)
@variable(m, batt_build[1:Nbatt], Bin)
@variable(m, StoreIn[1:steps]   >= 0)   
@variable(m, StoreOut[1:steps]  >= 0)  
@variable(m, InStorage[1:steps] >= 0)
@variable(m, station_additions[1:Nbuses] >= 0)
@variable(m, station_increment[1:Nbuses] >= 0)
@variable(m, constraint_incremented[1:Nconstraints], Bin)

# Avalibile capacity at bus constraint
# For each bus, station_additions equals the sum of capacities of all projects built at that bus
for (bus_idx_val, bus_id) in enumerate(bus_idx)
    @constraint(m,
        station_additions[bus_idx_val] ==
            sum(solar_build[i] * solar_capacity[i] for i in 1:Nsolar if solar_buses[i] == bus_id) +
            sum(wind_build[i]  * wind_capacity[i]  for i in 1:Nwind  if wind_buses[i]  == bus_id) +
            sum(gas_build[i]   * gas_capacity[i]   for i in 1:Ngas   if gas_buses[i]   == bus_id) +
            sum(batt_build[i]  * batt_capacity[i]  for i in 1:Nbatt  if batt_buses[i]  == bus_id)
    )
end
@constraint(m, [bus=1:Nbuses], station_additions[bus] <= bus_avail[bus-1] + station_increment[bus]) #-1 because index starts at 0

# constraint upgrade cost
@expression(m, upgrade_costs, sum(constraint_incremented[constraint] * constraint_to_cost_inc[constraint][2] for constraint in 1:Nconstraints))

# constraint linking station increment to constraint increment
@constraint(m, [constraint=1:Nconstraints], constraint_incremented[constraint] * constraint_to_cost_inc[constraint][3] == 
                sum(station_increment[bus] for bus in 1:Nbuses if bus_upgrade[bus-1] == constraint)) #-1 because index starts at 0

# Available output (as before)
@expression(m, solar_available[t=1:steps], sum(solar_build[i] * solar_capacity[i] * solar_cf[t] for i in 1:Nsolar))
@expression(m, wind_available[t=1:steps],  sum(wind_build[i] * wind_capacity[i] * wind_cf[t]  for i in 1:Nwind))
@expression(m, gas_available[t=1:steps], sum(gas_build[i] * gas_capacity[i] for i in 1:Ngas))

# availalable power and store avail for batteries
@expression(m, batt_pwr_available, sum(batt_build[i] * batt_capacity[i] for i in 1:Nbatt))
@expression(m, batt_store_available, sum(batt_build[i] * batt_storage[i] for i in 1:Nbatt))

# New variables for dispatched output (renewables can be curtailed)
@variable(m, solar_dispatch[1:steps] >= 0)
@variable(m, wind_dispatch[1:steps]  >= 0)
@variable(m, gas_dispatch[1:steps] >= 0)

# First week: storage starts from initial_soc
@constraint(m, InStorage[1] == batt_store_available * inital_soc)
# Last week: storage starts from final_soc TODO adding this makes the model weird 
@constraint(m, InStorage[steps] == batt_store_available * final_soc)

# ensuring that battery does not charge and discharge at same time
# @variable(m, b_mode[1:steps], Bin)
# @constraint(m, [t=1:steps], StoreIn[t] ≤ M * b_mode[t])
# @constraint(m, [t=1:steps], StoreOut[t] ≤ M * (1 - b_mode[t]))

# counting how often battery charging changes by alot so that we can minimize and save battery life
depth_trigger = 0.1 * batt_store_available
@variable(m, s[2:steps] ≥ 0)                         # slack ≥ excess depth
@expression(m, Δ[t = 2:steps],  InStorage[t] - InStorage[t-1])   # hourly swing (MWh)
# Slack must cover the excess above +depth or –depth
@constraint(m, [t=2:steps],  s[t] ≥  Δ[t] - depth_trigger)
@constraint(m, [t=2:steps],  s[t] ≥ -Δ[t] - depth_trigger)
@expression(m, wear, sum(s[t] for t=2:steps))        # total MWh of “over-depth”

# Storage bounds for all t
for t = 1:steps
    @constraint(m, InStorage[t] <= batt_store_available)
    @constraint(m, StoreIn[t]  <= batt_pwr_available)
    @constraint(m, StoreOut[t] <= batt_pwr_available)
    @constraint(m, StoreOut[t] <= InStorage[t])
end

# Storage update for t >= 2
for t = 2:steps
    @constraint(m, InStorage[t] == InStorage[t-1] + StoreIn[t] * η_ch - StoreOut[t] / η_dis)
end

# Dispatched cannot exceed available
@constraint(m, [t=1:steps], solar_dispatch[t] <= solar_available[t])
@constraint(m, [t=1:steps], wind_dispatch[t]  <= wind_available[t])
@constraint(m, [t=1:steps], gas_dispatch[t]  <= gas_available[t])


# Power balance: supply == demand (allow for curtailemt)
@constraint(m, [t=1:steps], load_increase[t] == solar_dispatch[t] + wind_dispatch[t] + gas_dispatch[t] - StoreIn[t]/η_ch + (StoreOut[t]*η_dis))

# For each time step, batteries can only charge from excess generation
@constraint(m, [t=1:steps], StoreIn[t] <= solar_dispatch[t] + wind_dispatch[t] + gas_dispatch[t] - load_increase[t] + StoreOut[t]*η_dis)

# Curtailment; postive so that model does not increase negative curtailment
@expression(m, curtailment[t=1:steps], solar_available[t] + wind_available[t] - solar_dispatch[t] - wind_dispatch[t] - StoreIn[t]/η_ch)
@constraint(m, [t=1:steps], curtailment[t] >= 0)
@expression(m, total_curtailment_cost, sum(curtailment[t] * curtail_cost for t in 1:steps))

# Emissions
@expression(m, emissions, sum(gas_dispatch[t] * gas_emissions for t in 1:steps))

# Objective: total cost = project costs + curtailment + emissions
@objective(m, Min,
    sum(solar_build[i] * solar_proj_cost[i] for i in 1:Nsolar) +
    sum(wind_build[i]  * wind_proj_cost[i]  for i in 1:Nwind)  +
    sum(gas_build[i]   * gas_proj_cost[i]   for i in 1:Ngas)   +
    sum(batt_build[i] * batt_proj_cost[i] for i in 1:Nbatt) +
    total_curtailment_cost +
    emissions_cost * emissions + 
    upgrade_costs +
    StoreOut[1] * 1e12 + # we do not want to discharge on the first hour
    wear * wear_cost
)

optimize!(m)

println("\n--- Optimization Results ---")
println("Termination status: ", termination_status(m))

println("\nSelected Solar Projects:")
for i in 1:Nsolar
    if value(solar_build[i]) > 0.5
        println("  - ", solar_names[i], " at bus ", solar_buses[i], " | Capacity: ", solar_capacity[i], " MW")
    end
end

println("\nSelected Wind Projects:")
for i in 1:Nwind
    if value(wind_build[i]) > 0.5
        println("  - ", wind_names[i], " at bus ", wind_buses[i], " | Capacity: ", wind_capacity[i], " MW")
    end
end

println("\nSelected Gas Projects:")
for i in 1:Ngas
    if value(gas_build[i]) > 0.5
        println("  - ", gas_names[i], " at bus ", gas_buses[i], " | Capacity: ", gas_capacity[i], " MW")
    end
end

println("\nSelected Battery Projects:")
for i in 1:Nbatt
    if value(batt_build[i]) > 0.5
        println("  - ", batt_names[i], " at bus ", batt_buses[i], " | Capacity: ", batt_capacity[i], " MW")
    end
end

println("\nSelected Constraints Incremented:")
for i in 1:Nconstraints
    if value(constraint_incremented[i]) > 0.5
        println("  - Constraint: ", constraint_to_cost_inc[i][1], 
                " | Cost: \$", constraint_to_cost_inc[i][2], 
                " | Increment Amount: ", constraint_to_cost_inc[i][3])
    end
end

println("\nBuses Incremented:")
for i in 1:Nbuses
    if value(station_increment[i]) > 1e-6
        println("  - Bus IDX: ", bus_idx[i], 
                " | Name: ", bus_df.Station[i], 
                " | Incremented by: ", value(station_increment[i]))
    end
end

println("\n--- Capacity Additions ---")
total_solar_capacity = sum(solar_capacity[i] for i in 1:Nsolar if value(solar_build[i]) > 0.5)
total_wind_capacity = sum(wind_capacity[i] for i in 1:Nwind if value(wind_build[i]) > 0.5)
total_batt_capacity = sum(batt_capacity[i] for i in 1:Nbatt if value(batt_build[i]) > 0.5)
total_batt_storage = sum(batt_storage[i] for i in 1:Nbatt if value(batt_build[i]) > 0.5)

println("Total Solar Capacity Added (MW): ", total_solar_capacity)
println("Total Wind Capacity Added (MW): ", total_wind_capacity)
println("Total Battery Power Added (MW): ", total_batt_capacity)
println("Total Battery Storage Added (MWh): ", total_batt_storage)

println("\nObjective value (total cost): \$", objective_value(m))
max_load_val = maximum([value(load_increase[t]) for t in 1:steps])
println("Max modeled load (MW): ", max_load_val)

println("Total Emissions (tons CO₂): ", value(emissions))
println("Total Curtailment (MWh): ", sum(value.(curtailment)))
println("Total Upgrade Costs (\$): ", value(upgrade_costs))
println("Total Emissions Cost (\$): ", value(emissions) * emissions_cost)
println("Total Curtailment Cost (\$): ", value(total_curtailment_cost))

total_load = sum(value.(load_increase))
total_generation = sum(value.(solar_dispatch)) + sum(value.(wind_dispatch)) + sum(value.(gas_dispatch)) + sum(value.(StoreOut)) * η_dis - sum(value.(StoreIn) / η_ch)
println("Total Load (MWh): ", total_load)
println("Total (minus storage in) Generation (MWh): ", total_generation)

println("\n--- Generation and Storage Summary ---")
println("Total Solar Generation (MWh): ", sum(value.(solar_dispatch)))
println("Total Wind Generation (MWh): ", sum(value.(wind_dispatch)))
println("Total Gas Generation (MWh): ", sum(value.(gas_dispatch)))
println("Total Battery Charge (MWh): ", sum(value.(StoreIn)))
println("Total Battery Discharge (MWh): ", sum(value.(StoreOut)))

results_dir = "results"
isdir(results_dir) || mkdir(results_dir)

hours = 1:steps

solar_vals = value.(solar_dispatch)
wind_vals  = value.(wind_dispatch)
gas_vals   = value.(gas_dispatch)
batt_vals  = value.(StoreOut)*η_dis .- value.(StoreIn)/η_ch
load_vals  = value.(load_increase)

gr()

# Plot only the first week (24*7 = 168 hours)
week_hours = 1:(24*7*2) #change for diffrent runs and effects
p = plot(
    week_hours, [solar_vals[week_hours] wind_vals[week_hours] gas_vals[week_hours] batt_vals[week_hours]],
    #label=["Solar Dispatch" "Wind Dispatch" "Gas Dispatch" "Battery Dispatch"],
    xlabel="Hour", ylabel="Power (MW)",
    title="Stacked Resource Dispatch (First Week)",
    legend=false,
    lw=1.5,
    fillalpha=0.7,
    c=[:orange :blue :gray :purple],
    stacked=true
)
plot!(p, week_hours, load_vals[week_hours], label="Load", lw=2, lc=:black, linestyle=:dash)
savefig(p, joinpath(results_dir, "dispatch_plot.png"))

jan_week  = 169:336
apr_week  = 2329:2496
jul_week  = 4153:4320
oct_week  = 6529:6696

labels = ["Solar Dispatch" "Wind Dispatch" "Gas Dispatch" "Battery Dispatch"]

p1 = plot(
        jan_week, 
        [solar_vals[jan_week] wind_vals[jan_week] gas_vals[jan_week] batt_vals[jan_week]], 
        xlabel="Hour", ylabel="Power (MW)",
        label = labels,
        legend=:outertop,
        legend_column = -1,
        lw=1.5,
        fillalpha=0.7,
        c=[:orange :blue :gray :purple],
        stacked=true,
        title="Week of Jan 8")
plot!(p1, jan_week, load_vals[jan_week], label="Load", lw=2, lc=:black, linestyle=:dash)

p2 = plot(
        apr_week, 
        [solar_vals[apr_week] wind_vals[apr_week] gas_vals[apr_week] batt_vals[apr_week]], 
        xlabel="Hour", ylabel="Power (MW)",
        legend=false,
        lw=1.5,
        fillalpha=0.7,
        c=[:orange :blue :gray :purple],
        stacked=true,
        title="Week of Apr 8")
plot!(p2, apr_week, load_vals[apr_week], label="Load", lw=2, lc=:black, linestyle=:dash)

p3 = plot(
        jul_week, 
        [solar_vals[jul_week] wind_vals[jul_week] gas_vals[jul_week] batt_vals[jul_week]], 
        xlabel="Hour", ylabel="Power (MW)",
        legend=false,
        lw=1.5,
        fillalpha=0.7,
        c=[:orange :blue :gray :purple],
        stacked=true,
        title="Week of Jul 8")
plot!(p3, jul_week, load_vals[jul_week], label="Load", lw=2, lc=:black, linestyle=:dash)

p4 = plot(
        oct_week, 
        [solar_vals[oct_week] wind_vals[oct_week] gas_vals[oct_week] batt_vals[oct_week]], 
        label=labels, 
        xlabel="Hour", ylabel="Power (MW)",
        legend=false,
        lw=1.5,
        fillalpha=0.7,
        c=[:orange :blue :gray :purple],
        stacked=true,
        title="Week of Oct 14")
plot!(p4, oct_week, load_vals[oct_week], label="Load", lw=2, lc=:black, linestyle=:dash)
# Save each weekly plot to PNG with month names
savefig(p1, joinpath(results_dir, "dispatch_january.png"))
savefig(p2, joinpath(results_dir, "dispatch_april.png"))
savefig(p3, joinpath(results_dir, "dispatch_july.png"))
savefig(p4, joinpath(results_dir, "dispatch_october.png"))

# Dummy plot to hold the common legend
# legend_plot = plot(
#                 jan_week, 
#                 [solar_vals[jan_week] wind_vals[jan_week] gas_vals[jan_week] batt_vals[jan_week]]; label=labels, 
#                 legend=:top, 
#                 grid=false, 
#                 framestyle=:none, 
#                 c=[:orange :blue :gray :purple],
#                 ticks=nothing, 
#                 linealpha=0,
#                 xlabel="")
# plot!(legend_plot, jan_week, load_vals[oct_week], label="Load", lw=2, lc=:black, linestyle=:dash, linealpha=0)

# Combine all plots in one layout
final_plot = plot(p1, p2, p3, p4; 
                layout = @layout([a; b; c; d]),  # d gets more height
                size=(800, 1200), 
                top_margin = 5mm,
                left_margin = 10mm,
                right_margin = 15mm)
savefig(final_plot, joinpath(results_dir, "four_seasons_dispatch.png"))

# Plot battery state of charge (InStorage) for the first two weeks (24*7*2 = 336 hours)
soc_hours = 1:(24*7)
soc_vals = value.(InStorage)[soc_hours]

p_soc = plot(
    soc_hours, soc_vals,
    xlabel="Hour",
    ylabel="State of Charge (MWh)",
    title="Battery State of Charge (First Two Weeks)",
    legend=false,
    lw=2,
    lc=:purple
)
savefig(p_soc, joinpath(results_dir, "battery_soc_first2weeks.png"))


# Helper function to save variable arrays
function save_var_csv(var, name)
    df = DataFrame(var = value.(var))
    CSV.write(joinpath(results_dir, "$name.csv"), df)
end

# Save binary build decisions
save_var_csv(solar_build, "solar_build")
save_var_csv(wind_build, "wind_build")
save_var_csv(gas_build, "gas_build")
save_var_csv(batt_build, "batt_build")

# Save time series variables
dispatch_df = DataFrame(
    load = load_increase, 
    solar_dispatch = value.(solar_dispatch),
    wind_dispatch  = value.(wind_dispatch),
    gas_dispatch     = value.(gas_dispatch),
    curtailment      = value.(curtailment),
    StoreIn        = value.(StoreIn),
    StoreOut       = value.(StoreOut),
    InStorage      = value.(InStorage),
    solar_available = value.(solar_available), 
    wind_available = value.(wind_available),
)
CSV.write(joinpath(results_dir, "dispatch_timeseries.csv"), dispatch_df)

# Save expressions
save_var_csv(solar_available, "solar_available")
save_var_csv(wind_available, "wind_available")
save_var_csv(gas_available, "wind_available")
save_var_csv(curtailment, "curtailment")


# Add capacity additions and built projects to bus_df
bus_df.station_increment = [value(station_increment[i]) for i in 1:Nbuses]
capacity_additions = [value(station_additions[i]) for i in 1:Nbuses]
projects_built = [String[] for _ in 1:Nbuses]

for (i, bus_id) in enumerate(bus_idx)
    # Solar
    for j in 1:Nsolar
        if solar_buses[j] == bus_id && value(solar_build[j]) > 0.5
            push!(projects_built[i], "Solar: $(solar_names[j])")
        end
    end
    # Wind
    for j in 1:Nwind
        if wind_buses[j] == bus_id && value(wind_build[j]) > 0.5
            push!(projects_built[i], "Wind: $(wind_names[j])")
        end
    end
    # Gas
    for j in 1:Ngas
        if gas_buses[j] == bus_id && value(gas_build[j]) > 0.5
            push!(projects_built[i], "Gas: $(gas_names[j])")
        end
    end
    # Battery
    for j in 1:Nbatt
        if batt_buses[j] == bus_id && value(batt_build[j]) > 0.5
            push!(projects_built[i], "Battery: $(batt_names[j])")
        end
    end
end

bus_df.capacity_additions = capacity_additions
bus_df.projects_built = [join(p, "; ") for p in projects_built]

CSV.write(joinpath(results_dir, "bus_results.csv"), bus_df)

# Save constraint upgrade results to CSV
constraint_results = DataFrame(
    constraint_id = [constraint_to_cost_inc[i][1] for i in 1:Nconstraints],
    was_incremented = [value(constraint_incremented[i]) > 0.5 for i in 1:Nconstraints],
    cost = [constraint_to_cost_inc[i][2] for i in 1:Nconstraints],
    increment_amount = [constraint_to_cost_inc[i][3] for i in 1:Nconstraints]
)

CSV.write(joinpath(results_dir, "constraint_results.csv"), constraint_results)

# Save the slack variable s to CSV
s_df = DataFrame(slack = [value(s[t]) for t in 2:steps])
CSV.write(joinpath(results_dir, "slack_s.csv"), s_df)