#!/usr/bin/env python3
"""Incremental lossy-file dedup for the music libraries (docker-prod, root cron).

Whenever a FLAC of the same track (artist+title) or same album (album_artist+album)
exists in either library, the lossy copy (mp3/m4a/aac/ogg/opus — wav is left alone,
being lossless) is MOVED to /data/quarantine/replaced-mp3s/ preserving its relative
path. Nothing is deleted; every move is appended to dedup.log. Idempotent.

Reads Navidrome's DB read-only (library_id 2 = amirah -> /data/music_amirah,
3 = diego -> /data/music; the root library is skipped to avoid double counting).
Navidrome reconciles the moves on its next scan (Tidarr triggers one per download).
"""
import os
import shutil
import sqlite3
import time

DB = '/docker/navidrome/navidrome.db'
LIBMAP = {2: '/data/music_amirah', 3: '/data/music'}
QUAR = '/data/quarantine/replaced-mp3s'
LOSSY = ('mp3', 'm4a', 'aac', 'ogg', 'opus')
LOG = os.path.join(QUAR, 'dedup.log')


def norm(s):
    return ' '.join(''.join(c for c in (s or '').lower() if c.isalnum() or c == ' ').split())


con = sqlite3.connect(f'file:{DB}?mode=ro', uri=True)
rows = con.execute("""
  select f.library_id, f.path, lower(f.suffix), f.title, f.artist,
         coalesce(f.album_artist, f.artist), a.name, f.missing
  from media_file f
  left join album a on f.album_id = a.id
  where f.library_id in (2, 3)
""").fetchall()

flac_tracks, flac_albums, lossy = set(), set(), {}
for lib, rel, suffix, title, artist, albart, album, missing in rows:
    if missing or not rel or lib not in LIBMAP:
        continue
    host = os.path.join(LIBMAP[lib], rel)
    if suffix == 'flac':
        flac_tracks.add((norm(artist), norm(title)))
        flac_albums.add((norm(albart), norm(album)))
    elif suffix in LOSSY:
        lossy[host] = (artist, title, albart, album)

moved, errs = 0, 0
os.makedirs(QUAR, exist_ok=True)
stamp = time.strftime('%F %T')
with open(LOG, 'a') as log:
    for host, (artist, title, albart, album) in lossy.items():
        replaceable = ((norm(artist), norm(title)) in flac_tracks or
                       (norm(albart), norm(album)) in flac_albums)
        if not replaceable:
            continue
        base = rel = None
        for libroot in LIBMAP.values():
            if host.startswith(libroot + '/'):
                base, rel = libroot, host[len(libroot) + 1:]
                break
        if not base:
            continue
        dest = os.path.join(QUAR, os.path.basename(base), rel)
        try:
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if os.path.exists(dest):
                os.remove(host)
            else:
                shutil.move(host, dest)
            log.write(f"{stamp}\t{host}\t->\t{dest}\n")
            moved += 1
        except OSError as e:
            log.write(f"{stamp}\tERR\t{host}\t{e}\n")
            errs += 1
print(f"dedup: lossy_candidates={len(lossy)} moved={moved} errors={errs}")
