import yaml
import requests
import re
from datetime import datetime
import statistics
import sys
from pathlib import Path

# URLs
ALA_BASE = "https://archive.archlinux.org/packages"
CACHY_REPOS = [
    "https://cdn77.cachyos.org/repo/x86_64_v4/cachyos-v4/",
    "https://cdn77.cachyos.org/repo/x86_64_v4/cachyos-extra-v4/",
    "https://cdn77.cachyos.org/repo/x86_64_v4/cachyos-core-v4/"
]

def get_arch_archive_dates(pkg_name):
    """Scrape the Arch Linux Archive for a specific package's history."""
    if not pkg_name: return []
    
    first_letter = pkg_name[0].lower()
    url = f"{ALA_BASE}/{first_letter}/{pkg_name}/"
    
    try:
        response = requests.get(url, timeout=5)
        if response.status_code != 200:
            return []
        
        date_pattern = re.compile(r'(\d{2}-[a-zA-Z]{3}-\d{4} \d{2}:\d{2})')
        matches = date_pattern.findall(response.text)
        
        dates = []
        for date_str in matches:
            try:
                dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M")
                dates.append(dt)
            except ValueError:
                continue
                
        return sorted(list(set(dates)))
    except requests.RequestException:
        return []

def fetch_cachyos_repo_data():
    """Fetch CachyOS repo indexes once to avoid spamming the CDN."""
    print("Fetching CachyOS repository indexes...")
    repo_data = {}
    
    for repo_url in CACHY_REPOS:
        try:
            response = requests.get(repo_url, timeout=10)
            if response.status_code == 200:
                pattern = re.compile(r'<a href="([^"]+\.pkg\.tar\.zst)">.*?</a>\s+(\d{2}-[a-zA-Z]{3}-\d{4} \d{2}:\d{2})')
                matches = pattern.findall(response.text)
                
                for filename, date_str in matches:
                    pkg_match = re.match(r'^([a-zA-Z0-9_\-]+?)-\d', filename)
                    if pkg_match:
                        pkg_name = pkg_match.group(1)
                        if pkg_name not in repo_data:
                            repo_data[pkg_name] = []
                        try:
                            dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M")
                            repo_data[pkg_name].append(dt)
                        except ValueError:
                            pass
        except requests.RequestException:
            print(f"Warning: Failed to fetch {repo_url}")
            
    for pkg in repo_data:
        repo_data[pkg] = sorted(list(set(repo_data[pkg])))
        
    return repo_data

def calculate_average_days(dates):
    """Calculate the average interval between a sorted list of datetimes."""
    if len(dates) < 2:
        return None
        
    intervals = []
    for i in range(1, len(dates)):
        delta = (dates[i] - dates[i-1]).days
        if delta > 0: 
            intervals.append(delta)
            
    if not intervals:
        return None
        
    return statistics.mean(intervals)

def categorize_interval(avg_days):
    """Categorize the average days into defined buckets."""
    if avg_days is None:
        return "unknown"
    if avg_days <= 2:
        return "daily"
    elif avg_days <= 10:
        return "weekly"
    elif avg_days <= 20:
        return "biweekly"
    elif avg_days <= 45:
        return "monthly"
    elif avg_days <= 120:
        return "quarterly"
    else:
        return "yearly"

def main(input_yaml, output_yaml):
    print(f"Reading {input_yaml}...")
    with open(input_yaml, 'r') as f:
        data = yaml.safe_load(f)
        
    if not data:
        print("YAML file is empty or invalid.")
        return

    cachy_repo_data = fetch_cachyos_repo_data()
    
    analyzed_data = {}
    
    # Count total packages for the progress tracker
    total_packages = sum(len(pkgs) for pkgs in data.values() if pkgs)
    processed = 0

    print(f"Found {total_packages} packages across {len(data)} components. Beginning analysis...")
    
    for component_tag, pkgs in data.items():
        if not pkgs:
            continue
            
        # Initialize the intervals for this specific component tag
        analyzed_data[component_tag] = {
            "daily": [],
            "weekly": [],
            "biweekly": [],
            "monthly": [],
            "quarterly": [],
            "yearly": [],
            "unknown": []
        }
        
        for pkg in pkgs:
            processed += 1
            print(f"[{processed}/{total_packages}] Analyzing {pkg} (in {component_tag})...")
            
            dates = get_arch_archive_dates(pkg)
            
            if not dates and pkg in cachy_repo_data:
                dates = cachy_repo_data[pkg]
                
            avg_days = calculate_average_days(dates)
            category = categorize_interval(avg_days)
            
            analyzed_data[component_tag][category].append(pkg)
        
        # Clean up empty intervals within the component tag
        cleaned_component = {}
        for category, pkg_list in analyzed_data[component_tag].items():
            if pkg_list:
                pkg_list.sort()
                cleaned_component[category] = pkg_list
        
        analyzed_data[component_tag] = cleaned_component

    # Remove any component tags that somehow ended up completely empty
    analyzed_data = {k: v for k, v in analyzed_data.items() if v}

    with open(output_yaml, 'w') as f:
        yaml.dump(analyzed_data, f, default_flow_style=False, sort_keys=False)
        
    print(f"Analysis complete. Results saved to {output_yaml}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python analyze_cadence_nested.py <input.yml> <output-analyzed.yml>")
        sys.exit(1)
        
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    if not Path(input_file).exists():
        print(f"Error: Input file '{input_file}' not found.")
        sys.exit(1)
        
    main(input_file, output_file)