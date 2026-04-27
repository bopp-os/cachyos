#! /usr/bin/env python
import os
import yaml
import aiohttp
import asyncio
import re
from datetime import datetime
import statistics
import sys
import argparse
import logging
from pathlib import Path

# URLs
ALA_BASE = "https://archive.archlinux.org/packages"
CACHY_REPOS = [
    ("x86_64_v4", "cachyos-v4"),
    ("x86_64_v4", "cachyos-extra-v4"),
    ("x86_64_v4", "cachyos-core-v4"),
    ("x86_64", "cachyos"),
    ("x86_64", "cachyos-extra"),
    ("x86_64", "cachyos-core")
]
CACHY_MIRROR_BASE = "https://mirror.cachyos.org/repo"
CACHY_ARCHIVE_BASE = "https://archive.cachyos.org/archive"

async def get_arch_archive_dates(session, pkg_name):
    """Scrape the Arch Linux Archive for a specific package's history."""
    if not pkg_name: return []
    
    first_letter = pkg_name[0].lower()
    url = f"{ALA_BASE}/{first_letter}/{pkg_name}/"
    
    logging.debug(f"[{pkg_name}] Arch Archive: Fetching {url}")
    try:
        async with session.get(url, timeout=10) as response:
            if response.status != 200:
                logging.debug(f"[{pkg_name}] Arch Archive: HTTP {response.status}")
                return []
            
            text = await response.text()
            date_pattern = re.compile(r'(\d{2}-[a-zA-Z]{3}-\d{4} \d{2}:\d{2})')
            matches = date_pattern.findall(text)
            
            dates = []
            for date_str in matches:
                try:
                    dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M")
                    dates.append(dt)
                except ValueError:
                    continue
                    
            unique_dates = sorted(list(set(dates)))
            logging.debug(f"[{pkg_name}] Arch Archive: Found {len(unique_dates)} history entries")
            return unique_dates
    except Exception as e:
        logging.debug(f"[{pkg_name}] Arch Archive: Request failed - {e}")
        return []

async def get_chaotic_aur_dates(session, pkg_name):
    """Scrape the Chaotic-AUR repository commits via GitHub API for a specific package's history."""
    if not pkg_name: return []
    
    url = f"https://api.github.com/repos/chaotic-aur/packages/commits?path={pkg_name}/PKGBUILD"
    headers = {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'BoppOS-Package-Analyzer'
    }
    
    token = os.environ.get('GITHUB_TOKEN')
    if token:
        headers['Authorization'] = f'Bearer {token}'
        
    logging.debug(f"[{pkg_name}] Chaotic-AUR: Fetching {url}")
    try:
        async with session.get(url, headers=headers, timeout=15) as response:
            if response.status == 403:
                logging.warning(f"[{pkg_name}] Chaotic-AUR: GitHub API Rate Limit Exceeded (403). Set GITHUB_TOKEN to bypass.")
                return []
            if response.status == 404:
                logging.debug(f"[{pkg_name}] Chaotic-AUR: Package not found (404).")
                return []
            if response.status != 200:
                logging.debug(f"[{pkg_name}] Chaotic-AUR: HTTP {response.status}")
                return []
            
            data = await response.json()
            dates = []
            for item in data:
                try:
                    date_str = item['commit']['author']['date']
                    dt = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%SZ")
                    dates.append(dt)
                except (KeyError, ValueError, TypeError):
                    continue
                    
            unique_dates = sorted(list(set(dates)))
            logging.debug(f"[{pkg_name}] Chaotic-AUR: Found {len(unique_dates)} history entries")
            return unique_dates
    except Exception as e:
        logging.debug(f"[{pkg_name}] Chaotic-AUR: Request failed - {e}")
        return []

async def fetch_all_cachyos_data(session):
    """Fetch and parse all CachyOS mirrors and archives once to build a local historical database."""
    cachy_data = {}
    urls_to_fetch = set()
    
    # Live mirrors have core/extra subdirectories
    for arch, repo in CACHY_REPOS:
        urls_to_fetch.add(f"{CACHY_MIRROR_BASE}/{arch}/{repo}/")

    # Archives consolidate packages into a single directory per architecture
    urls_to_fetch.add(f"{CACHY_ARCHIVE_BASE}/cachyos/")
    urls_to_fetch.add(f"{CACHY_ARCHIVE_BASE}/cachyos-v3/")
    urls_to_fetch.add(f"{CACHY_ARCHIVE_BASE}/cachyos-v4/")

    logging.info(f"Fetching {len(urls_to_fetch)} CachyOS directory indexes to build history cache...")
    
    # Matches: href="pkgname-1.0-1-x86_64_v4.pkg.tar.zst" ... <td class="date">YYYY-MMM-dd hh:mm</td>
    pattern = re.compile(r'href="([^"]+\.pkg\.tar\.zst)".*?<td class="date">(\d{4}-[a-zA-Z]{3}-\d{2} \d{2}:\d{2})</td>')
    
    async def fetch_url(url):
        logging.debug(f"Fetching directory index: {url}")
        try:
            async with session.get(url, timeout=15) as response:
                if response.status == 200:
                    return await response.text()
        except Exception as e:
            logging.debug(f"Failed to fetch {url}: {e}")
        return ""

    html_pages = await asyncio.gather(*(fetch_url(url) for url in sorted(list(urls_to_fetch))))
    
    for html in html_pages:
        if not html: continue
        matches = pattern.findall(html)
        for filename, date_str in matches:
            pkg_match = re.match(r'^([a-zA-Z0-9_\-\.\+]+?)-\d', filename)
            if pkg_match:
                pkg_name = pkg_match.group(1)
                try:
                    dt = datetime.strptime(date_str, "%Y-%b-%d %H:%M")
                    if pkg_name not in cachy_data:
                        cachy_data[pkg_name] = set()
                    cachy_data[pkg_name].add(dt)
                except ValueError:
                    pass
                    
    # Convert sets to sorted lists
    for pkg, dates in cachy_data.items():
        cachy_data[pkg] = sorted(list(dates))
        
    logging.info(f"Successfully cached history for {len(cachy_data)} CachyOS packages.")
    return cachy_data

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

async def analyze_package(session, pkg, cachy_data):
    """Analyze a single package using both Arch Archive and local CachyOS data."""
    dates = await get_arch_archive_dates(session, pkg)
    
    if not dates or len(dates) < 2:
        logging.debug(f"[{pkg}] Insufficient history in Arch Archive. Checking local CachyOS cache...")
        cachy_dates = cachy_data.get(pkg, [])
        if cachy_dates:
            logging.debug(f"[{pkg}] Found {len(cachy_dates)} history entries in CachyOS cache.")
            if len(cachy_dates) > len(dates):
                dates = cachy_dates
        else:
            logging.debug(f"[{pkg}] No history found in CachyOS cache.")
            
    if not dates or len(dates) < 2:
        logging.debug(f"[{pkg}] Insufficient history. Checking Chaotic-AUR via GitHub API...")
        chaotic_dates = await get_chaotic_aur_dates(session, pkg)
        if chaotic_dates and len(chaotic_dates) > len(dates):
            dates = chaotic_dates
            
    avg_days = calculate_average_days(dates)
        
    if avg_days is not None:
        category = categorize_interval(avg_days)
    elif dates and len(dates) == 1:
        age_days = (datetime.now() - dates[0]).days
        if age_days >= 365:
            category = "yearly"
            logging.debug(f"[{pkg}] Single release is {age_days} days old. Defaulting to yearly.")
        else:
            category = "unknown"
            logging.debug(f"[{pkg}] Single release is only {age_days} days old. Keeping as unknown.")
    else:
        category = "unknown"
    
    logging.debug(f"[{pkg}] Calculated avg_days: {avg_days} -> Category: {category}")
    return pkg, category

async def process_packages(data):
    analyzed_data = {}
    packages_to_process = []
    
    for component_tag, pkgs in data.items():
        if pkgs:
            for pkg in pkgs:
                packages_to_process.append((component_tag, pkg))

    total_packages = len(packages_to_process)
    logging.info(f"Found {total_packages} packages across {len(data)} components. Beginning analysis...")
    
    semaphore = asyncio.Semaphore(15)
    processed_counter = [0]

    async with aiohttp.ClientSession() as session:
        cachy_data = await fetch_all_cachyos_data(session)

        async def bounded_analyze(component_tag, pkg):
            async with semaphore:
                pkg_name, category = await analyze_package(session, pkg, cachy_data)
                processed_counter[0] += 1
                logging.info(f"[{processed_counter[0]}/{total_packages}] Analyzed {pkg_name} (in {component_tag}) -> {category}")
                return component_tag, pkg_name, category

        tasks = [bounded_analyze(comp, pkg) for comp, pkg in packages_to_process]
        results = await asyncio.gather(*tasks)

    for comp, pkg, category in results:
        if comp not in analyzed_data:
            analyzed_data[comp] = {
                "daily": [], "weekly": [], "biweekly": [], 
                "monthly": [], "quarterly": [], "yearly": [], "unknown": []
            }
        analyzed_data[comp][category].append(pkg)

    for comp in list(analyzed_data.keys()):
        cleaned_component = {}
        for category, pkg_list in analyzed_data[comp].items():
            if pkg_list:
                pkg_list.sort()
                cleaned_component[category] = pkg_list
        if cleaned_component:
            analyzed_data[comp] = cleaned_component
        else:
            del analyzed_data[comp]

    return analyzed_data

def main(input_yaml, output_yaml):
    logging.info(f"Reading {input_yaml}...")
    with open(input_yaml, 'r') as f:
        data = yaml.safe_load(f)
        
    if not data:
        logging.error("YAML file is empty or invalid.")
        return

    analyzed_data = asyncio.run(process_packages(data))
    
    with open(output_yaml, 'w') as f:
        yaml.dump(analyzed_data, f, default_flow_style=False, sort_keys=False)
        
    logging.info(f"Analysis complete. Results saved to {output_yaml}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Analyze package update cadences.")
    parser.add_argument("input_file", help="Input YAML file")
    parser.add_argument("output_file", help="Output analyzed YAML file")
    parser.add_argument("--debug", "-d", action="store_true", help="Enable verbose debug output")
    args = parser.parse_args()
    
    log_level = logging.DEBUG if args.debug else logging.INFO
    logging.basicConfig(level=log_level, format='%(message)s')
    
    if not Path(args.input_file).exists():
        logging.error(f"Error: Input file '{args.input_file}' not found.")
        sys.exit(1)
        
    main(args.input_file, args.output_file)