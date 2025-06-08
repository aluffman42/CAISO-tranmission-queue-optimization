import pandas as pd

# Read the CSV file
cost = pd.read_csv('cost_per_bus.csv')


space = pd.read_csv('latlong + available now.csv')

# Merge small and large on the substation name
merged = pd.merge(
    cost,
    space,
    left_on='Station',
    right_on='Name',
    how='left'
)

merged.to_csv('fullstations.csv', index=False)