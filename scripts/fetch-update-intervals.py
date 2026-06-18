#!/usr/bin/env python3
import argparse
import asyncio
import json
import logging
import os
import statistics
import re
import sys
from urllib.parse import unquote
from datetime import datetime, timezone
from pathlib import Path

import aiohttp
from bs4 import BeautifulSoup

ALA_BASE = "https://archive.archlinux.org/packages"
CACHY_MIRROR_BASE = "https://mirror.cachyos.org/repo"
CACHY_ARCHIVE_BASE = "https://archive.cachyos.org/archive"
BOPPOS_REPO_BASE = "https://repo.ripps.me"
CACHY_REPOS = [
    ("x86_64_v4", "cachyos-v4"),
    ("x86_64_v4", "cachyos-extra-v4"),
    ("x86_64_v4", "cachyos-core-v4"),
    ("x86_64", "cachyos"),
    ("x86_64", "cachyos-extra"),
    ("x86_64", "cachyos-core")
]

def get_bucket(median_days):
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
            # Unquote URL encoding (e.g., %3A -> :) to accurately parse epochs and symbols
            filename = unquote(filename)
            m = re.match(r'^(.+)-([^-]+-[^-]+)-(?:x86_64|x86_64_v3|x86_64_v4|znver4|aarch64|any)\.pkg\.tar\.[a-z]+$', filename)
            if m:
                pkg_name = m.group(1)
                pkg_version = m.group(2)
                try:
                    if len(date_str.split('-')[0]) == 4:
                        dt = datetime.strptime(date_str, "%Y-%b-%d %H:%M").replace(tzinfo=timezone.utc)
                    else:
                        dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M").replace(tzinfo=timezone.utc)
                        
                    if pkg_name not in cachy_data:
                        cachy_data[pkg_name] = {}
                    # Keep the oldest timestamp representing the original release date of this version
                    if pkg_version not in cachy_data[pkg_name] or cachy_data[pkg_name][pkg_version] > dt:
                        cachy_data[pkg_name][pkg_version] = dt
                except ValueError:
                    pass
                    
    return cachy_data

async def fetch_all_boppos_data(session):
    """Fetch BoppOS repository index."""
    boppos_data = {}
    logging.info("Fetching BoppOS directory index...")
    
    html = await fetch_with_backoff(session, f"{BOPPOS_REPO_BASE}/")
    if not html: return boppos_data
    
    soup = BeautifulSoup(html, 'html.parser')
    for tr in soup.find_all('tr', class_='file'):
        a_tag = tr.find('a')
        time_tag = tr.find('time')
        
        if not a_tag or not time_tag or 'href' not in a_tag.attrs or 'datetime' not in time_tag.attrs:
            continue
            
        filename = unquote(a_tag['href']).split('/')[-1]
        date_str = time_tag['datetime']
        
        m = re.match(r'^(.+)-([^-]+-[^-]+)-(?:x86_64|x86_64_v3|x86_64_v4|znver4|aarch64|any)\.pkg\.tar\.[a-z]+$', filename)
        if m:
            pkg_name = m.group(1)
            pkg_version = m.group(2)
            try:
                dt = datetime.fromisoformat(date_str.replace('Z', '+00:00'))
                if pkg_name not in boppos_data:
                    boppos_data[pkg_name] = {}
                if pkg_version not in boppos_data[pkg_name] or boppos_data[pkg_name][pkg_version] > dt:
                    boppos_data[pkg_name][pkg_version] = dt
            except ValueError:
                pass
                
    return boppos_data

async def analyze_arch_package(session, pkg_name):
    first_letter = pkg_name[0].lower()
    url = f"{ALA_BASE}/{first_letter}/{pkg_name}/"
    
    html = await fetch_with_backoff(session, url)
    if not html: return {}, "ala_not_found"
    
    pattern = re.compile(r'href="([^"]+\.pkg\.tar\.[a-z]+)".*?(\d{2}-[a-zA-Z]{3}-\d{4} \d{2}:\d{2})')
    matches = pattern.findall(html)
    
    history = {}
    for filename, date_str in matches:
        filename = unquote(filename)
        m = re.match(r'^(.+)-([^-]+-[^-]+)-(?:x86_64|x86_64_v3|x86_64_v4|znver4|aarch64|any)\.pkg\.tar\.[a-z]+$', filename)
        if m and m.group(1) == pkg_name:
            version = m.group(2)
            try:
                dt = datetime.strptime(date_str, "%d-%b-%Y %H:%M").replace(tzinfo=timezone.utc)
                if version not in history or history[version] > dt:
                    history[version] = dt
            except ValueError:
                pass
            
    return history, "ala" if history else "ala_not_found"

async def analyze_cachy_package(session, pkg_name, cachy_bulk_data):
    history = cachy_bulk_data.get(pkg_name, {})
    return history, "cachyos_mirror" if history else "cachyos_not_found"

async def analyze_boppos_package(session, pkg_name, boppos_bulk_data):
    history = boppos_bulk_data.get(pkg_name, {})
    return history, "bopp-os" if history else "boppos_not_found"

async def process_package(session, pkg, is_cachyos, is_boppos, cache, max_age, semaphore, cachy_bulk_data, boppos_bulk_data):
    async with semaphore:
        now = datetime.now(timezone.utc)
        
        existing_entry = cache.get(pkg, {})
        history = {}
        
        # Migrate old format / load existing history
        if 'history' in existing_entry:
            for v, d_str in existing_entry['history'].items():
                try:
                    history[v] = datetime.fromisoformat(d_str.replace('Z', '+00:00'))
                except ValueError:
                    pass
                    
        # If we fetched very recently (e.g. < 3 days), use the cache to save network spam.
        # We no longer use `max_age` (e.g. 30 days) to skip network requests entirely because
        # we want to fetch new updates frequently to build the database.
        if 'fetched_at' in existing_entry and 'history' in existing_entry:
            try:
                fetched_at = datetime.fromisoformat(existing_entry['fetched_at'].replace('Z', '+00:00'))
                age_days = (now - fetched_at).days
                if age_days < 3:
                    return pkg, existing_entry
            except ValueError:
                pass

        logging.debug(f"Fetching cadence for {pkg} (CachyOS: {is_cachyos})")
        
        new_history = {}
        source = "database"
        
        if is_boppos:
            new_history, source = await analyze_boppos_package(session, pkg, boppos_bulk_data)
        elif is_cachyos:
            new_history, source = await analyze_cachy_package(session, pkg, cachy_bulk_data)
            if len(new_history) < 2: 
                ala_history, ala_source = await analyze_arch_package(session, pkg)
                new_history.update(ala_history)
                if ala_history:
                    source = ala_source
        else:
            new_history, source = await analyze_arch_package(session, pkg)
                
        # Merge new finds into the permanent history database
        for v, dt in new_history.items():
            if v not in history or history[v] > dt:
                history[v] = dt
            
        # Calculate interval from the complete history database
        dates = sorted(history.values())
        num_releases = len(dates)
        
        intervals = [(dates[i] - dates[i-1]).days for i in range(1, num_releases)]
        # Filter out 0-day intervals (multiple revisions pushed on the exact same day)
        intervals = [i for i in intervals if i > 0]
        
        median_days = statistics.median(intervals) if intervals else 0.0
        
        interval_lbl = get_bucket(median_days)
        
        if num_releases < 3:
            if num_releases == 1:
                age_days = (now - dates[0]).days
                if age_days < 10:
                    interval_lbl = "weekly"
                    logging.warning(f"[{pkg}] Only 1 release found (age: {age_days} days). Defaulting to weekly.")
                else:
                    interval_lbl = get_bucket(age_days)
                    logging.debug(f"[{pkg}] Single release is {age_days} days old. Bucketing as {interval_lbl}.")
            else:
                logging.debug(f"[{pkg}] Only {num_releases} historical releases found. Measured interval: {median_days} avg days. Bucketing as {interval_lbl}.")
                
        # Cap history size to prevent the database from growing infinitely
        MAX_HISTORY = 50
        if len(history) > MAX_HISTORY:
            # Keep the newest MAX_HISTORY entries (sorted chronologically)
            recent_items = sorted(history.items(), key=lambda x: x[1])[-MAX_HISTORY:]
            history = dict(recent_items)

        serializable_history = {v: dt.isoformat() for v, dt in history.items()}

        result = {
            "history": serializable_history,
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
    parser.add_argument("--boppos-packages", type=Path, help="File containing list of known BoppOS packages")
    parser.add_argument("--cache-file", type=Path, default=Path("tools/package-intervals.json"), help="Output JSON file")
    parser.add_argument("--max-age-days", type=int, default=30, help="Max age for cached entries")
    parser.add_argument("--concurrency", type=int, default=8, help="Concurrent HTTP requests")
    parser.add_argument("--dry-run", action="store_true", help="Print verbose changes and complete DB to stdout; skip writing to file")
    args = parser.parse_args()
    
    # Automatically elevate to DEBUG for maximum verbosity during a dry-run
    log_level = logging.DEBUG if args.dry_run else logging.INFO
    logging.basicConfig(level=log_level, format="%(message)s")
    
    pkg_list = [line.strip() for line in args.packages if line.strip()]
    cachy_pkgs = set()
    
    if args.cachyos_packages and args.cachyos_packages.exists():
        cachy_pkgs = {line.strip() for line in args.cachyos_packages.read_text().splitlines() if line.strip()}
        
    boppos_pkgs = set()
    if args.boppos_packages and args.boppos_packages.exists():
        boppos_pkgs = {line.strip() for line in args.boppos_packages.read_text().splitlines() if line.strip()}
        
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
        boppos_bulk_data = await fetch_all_boppos_data(session)
        
        tasks = []
        for pkg in pkg_list:
            is_cachy = pkg in cachy_pkgs
            is_boppos = pkg in boppos_pkgs
            tasks.append(process_package(session, pkg, is_cachy, is_boppos, cache, args.max_age_days, semaphore, cachy_bulk_data, boppos_bulk_data))
            
        results = await asyncio.gather(*tasks)
        
        for pkg, data in results:
            new_cache[pkg] = data
            
    # Maintain alphabetical ordering for diff cleanliness
    sorted_cache = {k: new_cache[k] for k in sorted(new_cache.keys())}
    
    # Calculate and display granular changes
    changes = []
    for pkg, data in sorted_cache.items():
        if pkg not in cache:
            changes.append(f"  [+] {pkg}: New package added (Interval: {data['interval']})")
            continue
            
        old_data = cache[pkg]
        old_interval = old_data.get('interval')
        new_interval = data['interval']
        
        pkg_changes = []
        if old_interval != new_interval:
            pkg_changes.append(f"Interval changed: {old_interval} -> {new_interval}")
            
        old_history = old_data.get('history', {})
        new_history = data.get('history', {})
        new_versions = set(new_history.keys()) - set(old_history.keys())
        if new_versions:
            pkg_changes.append(f"New versions added: {', '.join(new_versions)}")
            
        if pkg_changes:
            changes.append(f"  [*] {pkg}: {'; '.join(pkg_changes)}")

    if changes or args.dry_run:
        logging.info(f"\n=== CHANGES DETECTED ({len(changes)}) ===")
        for change in changes:
            logging.info(change)
        logging.info("========================\n")

    if args.dry_run:
        logging.info("DRY RUN: Skipping file write. Complete database follows:\n")
        print(json.dumps(sorted_cache, indent=2))
    else:
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