#!/usr/bin/env python3
import argparse
import asyncio
import json
import logging
import os
import statistics
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import aiohttp
from bs4 import BeautifulSoup

ALA_BASE = "https://archive.archlinux.org/packages"
CACHY_GITHUB_API = "https://api.github.com/repos/CachyOS/CachyOS-PKGBUILDS/commits"

def get_bucket(median_days, num_releases):
    if num_releases < 3:
        return "weekly"
    if median_days <= 2: return "daily"
    elif median_days <= 10: return "weekly"
    elif median_days <= 21: return "biweekly"
    elif median_days <= 45: return "monthly"
    elif median_days <= 120: return "quarterly"
    else: return "yearly"

async def fetch_with_backoff(session, url, headers=None, max_retries=3):
    for attempt in range(max_retries):
        try:
            async with session.get(url, headers=headers, timeout=15) as response:
                if response.status == 200:
                    return await response.text()
                elif response.status == 404:
                    return None
                elif response.status == 403:
                    logging.warning(f"Rate limited on {url}")
        except asyncio.TimeoutError:
            pass
        except Exception as e:
            logging.debug(f"Error fetching {url}: {e}")
        
        await asyncio.sleep(2 ** attempt)
    return None

async def analyze_arch_package(session, pkg_name):
    first_letter = pkg_name[0].lower()
    url = f"{ALA_BASE}/{first_letter}/{pkg_name}/"
    
    html = await fetch_with_backoff(session, url)
    if not html: return [], "ala_not_found"
    
    soup = BeautifulSoup(html, 'html.parser')
    dates = []
    for date_td in soup.find_all('td', class_='date'):
        try:
            dt = datetime.strptime(date_td.text.strip(), "%Y-%b-%d %H:%M")
            dates.append(dt)
        except ValueError:
            pass
            
    dates = sorted(list(set(dates)))
    return dates, "ala"

async def analyze_cachy_package(session, pkg_name):
    headers = {'Accept': 'application/vnd.github.v3+json', 'User-Agent': 'BoppOS-Chunkah'}
    if token := os.environ.get('GITHUB_TOKEN'):
        headers['Authorization'] = f'Bearer {token}'
        
    # Try searching multiple subdirectories where PKGBUILDs live
    subdirs = [pkg_name, f"core/{pkg_name}", f"extra/{pkg_name}"]
    dates = []
    
    for subdir in subdirs:
        url = f"{CACHY_GITHUB_API}?path={subdir}/PKGBUILD"
        resp_text = await fetch_with_backoff(session, url, headers)
        if not resp_text: continue
        
        data = json.loads(resp_text)
        if isinstance(data, list) and len(data) > 0:
            for item in data:
                try:
                    date_str = item['commit']['author']['date']
                    dt = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%SZ")
                    dates.append(dt)
                except (KeyError, ValueError):
                    pass
            break # Found the package directory
            
    dates = sorted(list(set(dates)))
    return dates, "cachyos_git"

async def analyze_aur_package(session, pkg_name):
    # 1. Resolve PackageBase from AUR RPC (required for correct cgit queries on split packages)
    rpc_url = f"https://aur.archlinux.org/rpc/v5/info/{pkg_name}"
    rpc_resp = await fetch_with_backoff(session, rpc_url)
    if not rpc_resp:
        return [], "aur_not_found"
        
    try:
        rpc_data = json.loads(rpc_resp)
        if rpc_data.get("resultcount", 0) == 0:
            return [], "aur_not_found"
        
        pkgbase = rpc_data["results"][0].get("PackageBase", pkg_name)
    except (json.JSONDecodeError, KeyError):
        pkgbase = pkg_name

    # 2. Fetch history from cgit Atom feed
    atom_url = f"https://aur.archlinux.org/cgit/aur.git/atom/?h={pkgbase}"
    xml = await fetch_with_backoff(session, atom_url)
    if not xml:
        return [], "aur_not_found"
        
    dates = []
    entries = re.findall(r'<entry>.*?</entry>', xml, re.DOTALL)
    for entry in entries:
        match = re.search(r'<updated>(.*?)</updated>', entry)
        if match:
            date_str = match.group(1)
            try:
                dt = datetime.strptime(date_str, "%Y-%m-%dT%H:%M:%SZ")
                dates.append(dt)
            except ValueError:
                try:
                    dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
                    dates.append(dt)
                except ValueError:
                    pass
    
    dates = sorted(list(set(dates)))
    return dates, "aur"

async def process_package(session, pkg, is_cachyos, is_aur, cache, max_age, semaphore):
    async with semaphore:
        now = datetime.now(timezone.utc)
        
        # Check cache
        if pkg in cache:
            cached_entry = cache[pkg]
            if 'fetched_at' in cached_entry:
                fetched_at = datetime.fromisoformat(cached_entry['fetched_at'].replace('Z', '+00:00'))
                age_days = (now - fetched_at).days
                if age_days <= max_age:
                    return pkg, cached_entry

        logging.debug(f"Fetching cadence for {pkg} (CachyOS: {is_cachyos})")
        
        if is_cachyos:
            dates, source = await analyze_cachy_package(session, pkg)
            if len(dates) < 2: # Fallback to ALA if CachyOS-specific check fails
                dates, source = await analyze_arch_package(session, pkg)
        elif is_aur:
            dates, source = await analyze_aur_package(session, pkg)
        else:
            dates, source = await analyze_arch_package(session, pkg)
            if len(dates) < 2 and source == "ala_not_found":
                dates, source = await analyze_aur_package(session, pkg)
            
        num_releases = len(dates)
        intervals = [(dates[i] - dates[i-1]).days for i in range(1, num_releases)]
        median_days = statistics.median(intervals) if intervals else 0.0
        
        interval_lbl = get_bucket(median_days, num_releases)
        
        if num_releases < 3:
            logging.warning(f"[{pkg}] Only {num_releases} historical releases found. Defaulting to weekly.")
            
        result = {
            "interval": interval_lbl,
            "avg_days": round(median_days, 2),
            "source": source,
            "fetched_at": now.isoformat()
        }
        
        return pkg, result

async def main():
    parser = argparse.ArgumentParser(description="Calculate chunkah update intervals for packages.")
    parser.add_argument("packages", nargs='?', type=argparse.FileType('r'), default=sys.stdin, help="List of packages (or stdin)")
    parser.add_argument("--cachyos-packages", type=Path, help="File containing list of known CachyOS packages")
    parser.add_argument("--aur-packages", type=Path, help="File containing list of known AUR packages")
    parser.add_argument("--cache-file", type=Path, default=Path("tools/package-intervals.json"), help="Output JSON file")
    parser.add_argument("--max-age-days", type=int, default=30, help="Max age for cached entries")
    parser.add_argument("--concurrency", type=int, default=8, help="Concurrent HTTP requests")
    args = parser.parse_args()
    
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    
    pkg_list = [line.strip() for line in args.packages if line.strip()]
    cachy_pkgs = set()
    
    if args.cachyos_packages and args.cachyos_packages.exists():
        cachy_pkgs = {line.strip() for line in args.cachyos_packages.read_text().splitlines() if line.strip()}
        
    aur_pkgs = set()
    if args.aur_packages and args.aur_packages.exists():
        aur_pkgs = {line.strip() for line in args.aur_packages.read_text().splitlines() if line.strip()}

    cache = {}
    if args.cache_file.exists():
        try:
            cache = json.loads(args.cache_file.read_text())
        except json.JSONDecodeError:
            pass

    logging.info(f"Analyzing {len(pkg_list)} packages (concurrency: {args.concurrency})...")
    
    semaphore = asyncio.Semaphore(args.concurrency)
    new_cache = {}
    
    async with aiohttp.ClientSession() as session:
        tasks = []
        for pkg in pkg_list:
            is_cachy = pkg in cachy_pkgs
            is_aur = pkg in aur_pkgs
            tasks.append(process_package(session, pkg, is_cachy, is_aur, cache, args.max_age_days, semaphore))
            
        results = await asyncio.gather(*tasks)
        
        for pkg, data in results:
            new_cache[pkg] = data
            
    # Maintain alphabetical ordering for diff cleanliness
    sorted_cache = {k: new_cache[k] for k in sorted(new_cache.keys())}
    
    args.cache_file.parent.mkdir(parents=True, exist_ok=True)
    with open(args.cache_file, "w") as f:
        json.dump(sorted_cache, f, indent=2)
        f.write("\n")
        
    logging.info(f"Wrote {len(sorted_cache)} entries to {args.cache_file}")

if __name__ == "__main__":
    # Fix for environments where stdin is closed early
    if sys.stdin.isatty():
        print("Please pipe a list of packages to this script, or pass a file argument.", file=sys.stderr)
        sys.exit(1)
    asyncio.run(main())