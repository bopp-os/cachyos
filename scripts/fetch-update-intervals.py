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
CACHY_MIRROR_BASE = "https://mirror.cachyos.org/repo"
CACHY_ARCHIVE_BASE = "https://archive.cachyos.org/archive"
CACHY_REPOS = [
    ("x86_64_v4", "cachyos-v4"),
    ("x86_64_v4", "cachyos-extra-v4"),
    ("x86_64_v4", "cachyos-core-v4"),
    ("x86_64", "cachyos"),
    ("x86_64", "cachyos-extra"),
    ("x86_64", "cachyos-core")
]

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

async def fetch_all_cachyos_data(session):
    """Bulk fetch all CachyOS mirrors and archives once to build a local historical database."""
    cachy_data = {}
    urls_to_fetch = {f"{CACHY_MIRROR_BASE}/{arch}/{repo}/" for arch, repo in CACHY_REPOS}
    urls_to_fetch.update({
        f"{CACHY_ARCHIVE_BASE}/cachyos/",
        f"{CACHY_ARCHIVE_BASE}/cachyos-v3/",
        f"{CACHY_ARCHIVE_BASE}/cachyos-v4/"
    })

    logging.info(f"Bulk fetching {len(urls_to_fetch)} CachyOS directory indexes...")
    
    # Resilient match for both table-based and standard nginx <pre> autoindexes
    pattern = re.compile(r'href="([^"]+\.pkg\.tar\.zst)".*?(\d{2,4}-[a-zA-Z]{3}-\d{2,4} \d{2}:\d{2})')
    
    html_pages = await asyncio.gather(*(fetch_with_backoff(session, url) for url in urls_to_fetch))
    
    for html in html_pages:
        if not html: continue
        matches = pattern.findall(html)
        for filename, date_str in matches:
            pkg_match = re.match(r'^([a-zA-Z0-9_\-\.\+]+?)-\d', filename)
            if pkg_match:
                pkg_name = pkg_match.group(1)
                try:
                    # Handle both YYYY-MMM-dd and dd-MMM-YYYY formats gracefully
                    if len(date_str.split('-')[0]) == 4:
                        dt = datetime.strptime(date_str, "%Y-%b-%d %H:%M")
                    else:
                        dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M")
                        
                    if pkg_name not in cachy_data:
                        cachy_data[pkg_name] = set()
                    cachy_data[pkg_name].add(dt)
                except ValueError:
                    pass
                    
    for pkg, dates in cachy_data.items():
        cachy_data[pkg] = sorted(list(dates))
    return cachy_data

async def analyze_arch_package(session, pkg_name):
    first_letter = pkg_name[0].lower()
    url = f"{ALA_BASE}/{first_letter}/{pkg_name}/"
    
    html = await fetch_with_backoff(session, url)
    if not html: return [], "ala_not_found"
    
    # Arch Linux Archive uses standard nginx autoindex inside a <pre> tag, not <td>.
    date_pattern = re.compile(r'(\d{2}-[a-zA-Z]{3}-\d{4} \d{2}:\d{2})')
    matches = date_pattern.findall(html)
    
    dates = []
    for date_str in matches:
        try:
            dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M")
            dates.append(dt)
        except ValueError as e:
            logging.debug(f"[{pkg_name}] Failed to parse ALA date '{date_str}': {e}")
            
    dates = sorted(list(set(dates)))
    return dates, "ala"

async def analyze_cachy_package(session, pkg_name, cachy_bulk_data):
    dates = cachy_bulk_data.get(pkg_name, [])
    if dates:
        return dates, "cachyos_mirror"
        
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

async def process_package(session, pkg, is_cachyos, is_aur, cache, max_age, semaphore, cachy_bulk_data):
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
            dates, source = await analyze_cachy_package(session, pkg, cachy_bulk_data)
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
            if num_releases == 1:
                age_days = (now - dates[0].replace(tzinfo=timezone.utc)).days
                if age_days >= 365:
                    interval_lbl = "yearly"
                    logging.debug(f"[{pkg}] Single release is {age_days} days old. Bucketing as yearly.")
                else:
                    logging.warning(f"[{pkg}] Only 1 recent release found. Defaulting to weekly.")
            else:
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
        cachy_bulk_data = await fetch_all_cachyos_data(session)
        
        tasks = []
        for pkg in pkg_list:
            is_cachy = pkg in cachy_pkgs
            is_aur = pkg in aur_pkgs
            tasks.append(process_package(session, pkg, is_cachy, is_aur, cache, args.max_age_days, semaphore, cachy_bulk_data))
            
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