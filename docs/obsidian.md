Trying to get obsidian to work not only by syncing the notes themselves, but also have some integration with git and configuration as well. Meaning I can write the documentation for my homelab using it.

Obsidian will be installed with both LiveSync and Git, Vim motions are also available and will be used.

I will be testing a push now, after having to enable personal access tokens to be able to push using my work laptop CLI rather than GitHub desktop.

## Obsidian config
Coming soon
## CouchDB (LiveSync server)
Stack `docker-compose/notes`, container `obsidian-livesync` on docker-prod, `https://notesdb.$DOMAIN`.

Settings live in `/docker/obsidian/livesync/etc/livesync.ini`, mounted as `/opt/couchdb/etc/local.d`
(owned by 1000:1000; the image also writes `docker.ini` there with the admin hash). The values match
upstream `utils/couchdb/provision.ts`: single node, `require_valid_user`, CORS enabled with origins
`app://obsidian.md,capacitor://localhost,http://localhost` and credentials, 4 GiB request and 50 MB
document limits.

Previously only `local.ini` was mounted, so settings applied through the `_config` API or the init
script were written to the container's own `local.d` and were lost when the container was recreated.
Sync then fails with "native fetch API failed, check CORS". Check with:
`curl -si -X OPTIONS https://notesdb.$DOMAIN/ -H 'Origin: app://obsidian.md' -H 'Access-Control-Request-Method: GET'`:
it must return 200 with `access-control-allow-origin: app://obsidian.md`.
