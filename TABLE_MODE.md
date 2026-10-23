# Running a table server on your laptop

Table mode runs this fork (with Fix history, the Ledger and Holdings) as a
private server for one game table. One laptop runs it; everyone at the table
opens it in a browser on their own phone, tablet or laptop over the same Wi-Fi.

What table mode changes from the public site:

- Signing up needs no captcha and no email confirmation, and any address works
  (`alice@table.local` is fine). Accounts work straight away.
- Fix history can commit corrected histories for everyone. The previous history
  is saved to `db/retcon_backups/` first.
- It can't run with the production settings, so it can't be switched on for
  the public site by mistake.

## One-time setup

1. **Install Docker.** On a Mac or Windows PC, install
   [Docker Desktop](https://www.docker.com/products/docker-desktop/) and start
   it. On Linux, install Docker Engine with the Compose plugin.
2. **Get `git` and `make`.**
   - Mac: run `xcode-select --install` in Terminal.
   - Windows: use WSL (open PowerShell as administrator, run `wsl --install`,
     restart, then open the Ubuntu app). Run every command below in that Ubuntu
     window, and in Docker Desktop's settings turn on WSL integration for
     Ubuntu. Then run `sudo apt install git make`.
   - Linux: install `git` and `make` with your package manager.
3. **Download the code.**

   ```
   git clone https://github.com/jkopinsky/18xx.git
   cd 18xx
   git checkout table-helper
   ```

## Starting the server

From the `18xx` folder:

```
make table_up
```

The first start downloads and builds everything, which takes a while (often
10 to 20 minutes). Later starts take about a minute. Right after starting, the
server compiles the app in the background (several minutes the first time,
much less afterwards) and then prints:

```
Table server ready: open http://localhost:9292 ...
```

Pages open quickly from then on. You can open a page before that line appears;
it just waits until compiling is done.

- **On the laptop:** open <http://localhost:9292>.
- **On other devices:** open `http://<laptop's address>:9292`, for example
  `http://192.168.1.23:9292`. To find the address, on a Mac run
  `ipconfig getifaddr en0` (or see System Settings > Wi-Fi > Details), and on
  Windows run `ipconfig` and use the IPv4 address. If the laptop's firewall
  asks whether to allow incoming connections, allow them.

To stop the server, press Ctrl+C in that window (or run `make table_down` from
another one). Games and accounts are kept in `db/data/` and are there again
the next time you start it.

## Playing a new game

1. Everyone opens the site and chooses **Sign Up**, then agrees to the privacy
   notice the first time they log in.
2. One person chooses **Create New Game**, picks 1817 or 1844, ticks
   **Auto Routing**, and creates it.
3. The others find it on their home page and press **Join**; the creator
   presses **Start**.

## Continuing a game from 18xx.games

1. Download the game's file from `https://18xx.games/api/game/<game number>`
   (save the page) or use **Tools > Download** on the game there.
2. Put the file in the `table_games` folder inside `18xx`.
3. With the server running, run, in another window:

   ```
   make table_import FILE=table_games/<file name>.json
   ```

   It prints the new game's number; open `http://<address>:9292/game/<number>`.

Each player in the file gets a local account named after them, with the email
`<name>@table.local` (letters and digits only, lower case) and the password
`password`. Players log in with those and can change the password on their
profile page. Add `--actions N` after the file name to import only the first N
actions.

## Updating

```
make table_down
git pull
make table_up
```

## If something goes wrong

- **Docker Desktop says it requires a newer macOS:** current versions need
  macOS 14 or later. For macOS 12 (Monterey), people report that Docker
  Desktop 4.41.2 is the last version that runs. Install it from Docker's
  download server (build 191736):
  - Apple chip (About This Mac shows "Chip: Apple M…"):
    <https://desktop.docker.com/mac/main/arm64/191736/Docker.dmg>
  - Intel chip (About This Mac shows "Processor: … Intel"):
    <https://desktop.docker.com/mac/main/amd64/191736/Docker.dmg>

  When it later offers an update, decline it (or turn off automatic updates in
  its settings): the update won't run on macOS 12. Docker removes old
  downloads over time; if the link stops working, a slightly older 4.x build
  also works for this.

- **`xcrun: error: invalid active developer path` on a Mac:** the Mac's command
  line tools (which provide `make`) are missing or were removed by a macOS
  update. Run `xcode-select --install`, finish the installer, and try again.
  If it says they're already installed, run
  `sudo rm -rf /Library/Developer/CommandLineTools` and then
  `xcode-select --install`.
- **Running without `make`:** from the `18xx` folder, run
  `mkdir -p db/data && chmod 700 db/data` once, then start the server with

  ```
  docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.table.yml build rack
  docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.table.yml up
  ```

  and import a game (with the server running) with

  ```
  docker compose -f docker-compose.yml -f docker-compose.dev.yml -f docker-compose.table.yml exec rack bundle exec ruby scripts/import_table_game.rb table_games/<file name>.json
  ```

- **A fix went wrong after it was committed:** every commit first saves the
  previous history in `db/retcon_backups/`. To go back to one, import that file
  as a new game with `make table_import FILE=db/retcon_backups/<file>.json`.
- **`make table_up` fails on a Mac with an Apple chip:** make sure Docker Desktop
  is up to date. The image picks the right build for the chip on its own.
- **`failed to solve: image "docker.io/library/18xx_rack:dev": already exists`:**
  two services built the same image at once. Update (`git pull`) and run
  `make table_up` again; it now builds the image once before starting.
- **Other devices can't connect:** check they are on the same Wi-Fi, that you
  used the laptop's address (not `localhost`), and that the firewall allows the
  connection.
