import pandas as pd
from rapidfuzz import process, fuzz
import re

# ========== 1. Enhanced function to clean constraint names ==========
def clean_constraint(name):
    if pd.isnull(name):
        return ''
    
    # Convert to string and strip
    name = str(name).strip()
    
    # Remove common constraint-related terms (case insensitive)
    patterns_to_remove = [
        r'(?i)\bconstraint\b',
        r'(?i)\bon-peak\b',
        r'(?i)\boff-peak\b', 
        r'(?i)\bon-peak/off-peak\b',
        r'(?i)\barea\b',
        r'(?i)\b(230\s*kv\s*bus\s*only)\b',
        r'(?i)\b(230\s*kv\s*only)\b'
    ]
    
    for pattern in patterns_to_remove:
        name = re.sub(pattern, '', name)
    
    # Standardize voltage notations
    name = re.sub(r'(?i)(\d+)\s*kv', r'\1kV', name)  # Standardize kV format
    
    # Standardize common abbreviations and variations
    replacements = {
        r'(?i)\bJct\b': 'Jct',
        r'(?i)\btb\b': 'TB',
        r'(?i)\bsw\s+sta\b': 'Sw Sta',
        r'(?i)\bblvd\b': 'Blvd',
        r'(?i)\bst\b': 'St',
        r'(?i)\bmtn\b': 'Mountain',
        r'(?i)\bmountain\b': 'Mountain',
        # Fix common name variations
        r'(?i)\blas\s+aguillas\b': 'Las Aguilas',
        r'(?i)\bignacio\b': 'Ignacio',
        r'(?i)\bpleaseant\b': 'Pleasant',
        r'(?i)\bjacksson-waukenacorcoran\b': 'Jackson-Waukena-Corcoran',
        r'(?i)\bwaukena\s*corcoran\b': 'Waukena-Corcoran'
    }
    
    for pattern, replacement in replacements.items():
        name = re.sub(pattern, replacement, name)
    
    # Clean up spacing around hyphens and standardize separators
    name = re.sub(r'\s*-\s*', '-', name)
    name = re.sub(r'\s*–\s*', '-', name)  # em dash to hyphen
    name = re.sub(r'\s*—\s*', '-', name)  # en dash to hyphen
    
    # Remove extra whitespace and clean up
    name = re.sub(r'\s+', ' ', name).strip()
    
    # Remove leading/trailing hyphens or spaces
    name = name.strip(' -')
    
    return name

# ========== 2. Additional function for ultra-clean matching ==========
def ultra_clean_constraint(name):
    """Even more aggressive cleaning for fuzzy matching"""
    clean_name = clean_constraint(name)
    
    # Remove all voltage references for better matching
    clean_name = re.sub(r'\d+kV', '', clean_name)
    
    # Remove line/transformer indicators
    clean_name = re.sub(r'(?i)\b(line|tb|transformer)\b', '', clean_name)
    clean_name = re.sub(r'#\d+', '', clean_name)  # Remove #1, #2, etc.
    
    # Remove directional indicators
    clean_name = re.sub(r'(?i)\b(north of|south of|east of|west of)\b', '', clean_name)
    
    # Clean up again
    clean_name = re.sub(r'\s+', ' ', clean_name).strip()
    clean_name = clean_name.strip(' -')
    
    return clean_name

# ========== 3. Load and clean costs data ==========
raw_costs = pd.read_excel('upgrade costs.xlsx', header=0).T
raw_costs.columns = raw_costs.iloc[0]
costs = raw_costs.drop(index=raw_costs.index[0])
costs = costs.reset_index().rename(columns={'index': 'Constraint'})
costs['Constraint'] = costs['Constraint'].astype(str).str.strip()
costs['CleanConstraint'] = costs['Constraint'].apply(clean_constraint)
costs['UltraCleanConstraint'] = costs['Constraint'].apply(ultra_clean_constraint)

# Convert numeric fields
costs['Inc'] = pd.to_numeric(costs['Inc'].astype(str).str.replace(',', ''), errors='coerce')
costs['Cost'] = pd.to_numeric(costs['Cost'].astype(str).str.replace(',', ''), errors='coerce')

# ========== 4. Load and clean constraints data ==========
constraints = pd.read_excel('constraint and bus.xlsx')
constraints['Constraint'] = constraints['Constraint'].astype(str).str.strip()
constraints['CleanConstraint'] = constraints['Constraint'].apply(clean_constraint)
constraints['UltraCleanConstraint'] = constraints['Constraint'].apply(ultra_clean_constraint)

# ========== 5. Multi-level fuzzy matching ==========
def multi_level_match(constraint_name, cost_df, threshold_high=95, threshold_med=85, threshold_low=75):
    """
    Try multiple levels of matching with different cleaning levels and scorers
    """
    constraint_clean = clean_constraint(constraint_name)
    constraint_ultra = ultra_clean_constraint(constraint_name)
    
    # Level 1: Exact match on cleaned names
    exact_match = cost_df[cost_df['CleanConstraint'] == constraint_clean]
    if not exact_match.empty:
        return exact_match.iloc[0]['CleanConstraint'], 100, 'exact_clean'
    
    # Level 2: High threshold with token_sort_ratio on clean names
    cost_clean_names = cost_df['CleanConstraint'].tolist()
    match, score, _ = process.extractOne(
        constraint_clean, 
        cost_clean_names, 
        scorer=fuzz.token_sort_ratio
    )
    if score >= threshold_high:
        return match, score, 'high_clean'
    
    # Level 3: Medium threshold with token_set_ratio on clean names
    match, score, _ = process.extractOne(
        constraint_clean, 
        cost_clean_names, 
        scorer=fuzz.token_set_ratio
    )
    if score >= threshold_med:
        return match, score, 'med_clean'
    
    # Level 4: Try ultra-clean names with lower threshold
    cost_ultra_names = cost_df['UltraCleanConstraint'].tolist()
    match_ultra, score_ultra, _ = process.extractOne(
        constraint_ultra, 
        cost_ultra_names, 
        scorer=fuzz.token_set_ratio
    )
    if score_ultra >= threshold_low:
        # Find the corresponding clean constraint name
        matched_row = cost_df[cost_df['UltraCleanConstraint'] == match_ultra].iloc[0]
        return matched_row['CleanConstraint'], score_ultra, 'ultra_clean'
    
    # Level 5: Partial ratio as last resort
    match, score, _ = process.extractOne(
        constraint_clean, 
        cost_clean_names, 
        scorer=fuzz.partial_ratio
    )
    if score >= threshold_low:
        return match, score, 'partial'
    
    return None, 0, 'no_match'

# Apply multi-level matching
match_results = constraints['Constraint'].apply(
    lambda x: multi_level_match(x, costs)
)

constraints['MatchedCleanConstraint'] = [result[0] for result in match_results]


# ========== 6. Merge using matched constraints ==========
merged = pd.merge(
    constraints,
    costs,
    left_on='MatchedCleanConstraint',
    right_on='CleanConstraint',
    how='left',
    suffixes=('_original', '_cost')
)

save_df = merged[['Station', 'Inc', 'Cost', 'Constraint_original']]

save_df.to_csv('cost_per_bus.csv', index=False)