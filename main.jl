using CSV, JuMP, Gurobi, DataFrames, Plots, FileIO
### Import the data

#Testing update

## solar and wind capacity factor

load_288 = "191_data_288_from_kmeansv2.csv"
load_288 = CSV.read(load_288, DataFrame)
solar_cf = load_288[:, 4]
wind_cf = load_288[:, 5]
load_increase = load_288[:, 3]


## population at each bus
bus_path = "fullstations.csv"
bus_df = CSV.read(bus_path, DataFrame)
bus_idx = bus_df[:, 1]
bus_avail = Dict(bus_df.IDX[i] => bus_df.Availability[i] for i in 1:nrow(bus_df))

##### BUS UPGRADE DICTIONARIES FOR ANDERS
bus_upgrade = Dict(bus_df.IDX[i] => bus_df.Constraint_original[i] for i in 1:nrow(bus_df))

# Remove duplicate constraints, keeping the first occurrence
unique_constraints = unique(bus_df, :Constraint_original)

# Create mapping from Constraint_original to (Cost, Inc) using only unique constraints
constraint_to_cost_inc = Dict(
    row.Constraint_original => (row.Cost, row.Inc) for row in eachrow(unique_constraints)
)

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
curtail_cost = 10           # $/MWh
emissions_cost = 150        # $/ton
gas_emissions = 0.20196     # ton/MWh
efficiency_batt = .95
inital_soc = 0.5

Nbuses = length(bus_idx)
Nsolar = length(solar_buses)
Nwind = length(wind_buses)
Ngas = length(gas_buses)
Nbatt = length(batt_buses)

steps = 288

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

# Available output (as before)
@expression(m, solar_available[t=1:steps], sum(solar_build[i] * solar_capacity[i] * solar_cf[t] for i in 1:Nsolar))
@expression(m, wind_available[t=1:steps],  sum(wind_build[i] * wind_capacity[i] * wind_cf[t]  for i in 1:Nwind))

##availalable power and store avail for batteries
@expression(m, batt_pwr_available, sum(batt_build[i] * batt_capacity[i] for i in 1:Nbatt))
@expression(m, batt_store_available, sum(batt_build[i] * batt_storage[i] for i in 1:Nbatt))

# New variables for dispatched output (can be curtailed)
@variable(m, solar_dispatch[1:steps] >= 0)
@variable(m, wind_dispatch[1:steps]  >= 0)

# First week: storage starts from initial_storage
@constraint(m, InStorage[1] == batt_store_available * inital_soc)

# Storage bounds for all t
for t = 1:steps
    @constraint(m, InStorage[t] <= batt_store_available)
    @constraint(m, StoreIn[t]  <= batt_pwr_available)
    @constraint(m, StoreOut[t] <= batt_pwr_available)
    @constraint(m, StoreOut[t] <= InStorage[t])
end

# Storage update for t >= 2
for t = 2:steps
    @constraint(m, InStorage[t] == InStorage[t-1] + StoreIn[t] - StoreOut[t])
end

# # Storage bounds
for t = 1:steps
     @constraint(m, InStorage[t] <= batt_store_available)
end

# Dispatched cannot exceed available
@constraint(m, [t=1:steps], solar_dispatch[t] <= solar_available[t])
@constraint(m, [t=1:steps], wind_dispatch[t]  <= wind_available[t])

# Gas output as the residual
@expression(m, gas_output[t=1:steps], load_increase[t] - solar_dispatch[t] - wind_dispatch[t] + StoreIn[t] - (StoreOut[t]) * efficiency_batt)

# Gas output cannot exceed available capacity and must be non-negative
@constraint(m, [t=1:steps], gas_output[t] <= sum(gas_build[i] * gas_capacity[i] for i in 1:Ngas))
@constraint(m, [t=1:steps], gas_output[t] >= 0)

# Power balance: supply >= demand
@constraint(m, [t=1:steps], load_increase[t] <= solar_dispatch[t] + wind_dispatch[t] + gas_output[t] - StoreIn[t] + (StoreOut[t]) * efficiency_batt)

# For each time step, batteries can only charge from excess generation
@constraint(m, [t=1:steps], StoreIn[t] <= solar_dispatch[t] + wind_dispatch[t] + gas_output[t] - load_increase[t] + StoreOut[t] * efficiency_batt)

# Curtailment, postive so that it does not increase negative curtailment
@expression(m, curtailment[t=1:steps], solar_available[t] + wind_available[t] - solar_dispatch[t] - wind_dispatch[t] - StoreIn[t])
@constraint(m, [t=1:steps], curtailment[t] >= 0)
@expression(m, total_curtailment_cost, sum(curtailment[t] * curtail_cost for t in 1:steps))

# Emissions
@expression(m, emissions,   sum(gas_output[t] * gas_emissions for t in 1:steps))

# Objective: total cost = project costs + curtailment + emissions
@objective(m, Min,
    sum(solar_build[i] * solar_proj_cost[i] for i in 1:Nsolar) +
    sum(wind_build[i]  * wind_proj_cost[i]  for i in 1:Nwind)  +
    sum(gas_build[i]   * gas_proj_cost[i]   for i in 1:Ngas)   +
    sum(batt_build[i] * batt_proj_cost[i] for i in 1:Nbatt) +
    total_curtailment_cost +
    emissions_cost * emissions
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

println("\nObjective value (total cost): \$", objective_value(m))
max_load_val = maximum([value(load_increase[t]) for t in 1:steps])
println("Max modeled load (MW): ", max_load_val)

println("Total Emissions (tons CO₂): ", value(emissions))
println("Total Curtailment (MWh): ", sum(value.(curtailment)))

total_load = sum(value.(load_increase))
total_generation = sum(value.(solar_dispatch)) + sum(value.(wind_dispatch)) + sum(value.(gas_output)) + sum(value.(StoreOut)) * efficiency_batt - sum(value.(StoreIn))
println("Total Load (MWh): ", total_load)
println("Total Generation (MWh): ", total_generation)

hours = 1:steps

solar_vals = value.(solar_dispatch)
wind_vals  = value.(wind_dispatch)
gas_vals   = value.(gas_output)
batt_vals  = value.(StoreOut) * efficiency_batt .- value.(StoreIn)
load_vals  = value.(load_increase)

gr()

p = plot(
    hours, [solar_vals wind_vals gas_vals batt_vals],
    label=["Solar Dispatch" "Wind Dispatch" "Gas Dispatch" "Battery Dispatch"],
    xlabel="Hour", ylabel="Power (MW)",
    title="Stacked Resource Dispatch Over Time",
    legend=:topright,
    lw=1.5,
    fillalpha=0.7,
    c=[:orange :blue :gray :purple],
    stacked=true
)
plot!(p, hours, load_vals, label="Load", lw=2, lc=:black, linestyle=:dash)
display(p)

results_dir = "results"
isdir(results_dir) || mkdir(results_dir)

savefig(p, joinpath(results_dir, "dispatch_plot.png"))


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
df = DataFrame(
    load = load_increase, 
    solar_dispatch = value.(solar_dispatch),
    wind_dispatch  = value.(wind_dispatch),
    gas_output     = value.(gas_output),
    StoreIn        = value.(StoreIn),
    StoreOut       = value.(StoreOut),
    InStorage      = value.(InStorage)
)
CSV.write(joinpath(results_dir, "dispatch_timeseries.csv"), df)

# Save expressions
save_var_csv(solar_available, "solar_available")
save_var_csv(wind_available, "wind_available")
save_var_csv(curtailment_pos, "curtailment_pos")
save_var_csv(curtailment, "curtailment")