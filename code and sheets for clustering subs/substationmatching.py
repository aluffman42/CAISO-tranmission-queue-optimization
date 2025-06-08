import pandas as pd

# Read the CSV file
small = pd.read_csv('smallsub.csv')

# Remove the 'XXX kV' (2 or 3 digits) from the end of the Name column
small['Name'] = small['Name'].str.replace(r'\s\d{2,3} kV$', '', regex=True)

# Convert Availability to numeric (handles commas and missing values)
small['Availability'] = pd.to_numeric(small['Availability'].astype(str).str.replace(',', ''), errors='coerce')

# For duplicates, keep the row with the smallest Availability value
small = small.loc[small.groupby('Name')['Availability'].idxmin()].reset_index(drop=True)

small['Lat'] = 0
small['Lon'] = 0


large = pd.read_csv('largesub.csv')

# Merge small and large on the substation name
merged = pd.merge(
    small,
    large[['NAME', 'LATITUDE', 'LONGITUDE']],
    left_on='Name',
    right_on='NAME',
    how='left'
)

# Now merged['LATITUDE'] and merged['LONGITUDE'] have the coordinates for matching names
save_df = merged[['Name', 'Availability', 'LATITUDE', 'LONGITUDE']]

save_df.to_csv('merged.csv', index=False)