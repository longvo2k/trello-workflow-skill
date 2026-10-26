# trello-workflow

A [Claude Code](https://claude.com/claude-code) skill for working with Trello and Bitbucket Cloud from
your terminal. It's the Trello sibling of
[jira-workflow](https://github.com/longvo2k/jira-workflow-skill) and
[redmine-workflow](https://github.com/longvo2k/redmine-workflow-skill).

- **Cards:** list your cards, create, move between lists, comment, assign, label, tick checklist
  items, set due dates
- **Requirements:** read a card's description, checklists, custom fields, attachments and full
  activity, then get a summary with open questions
- **Bitbucket:** find branches and PRs for a card, read PR diffs, review comments, commits, pipelines
- **Time logging:** log hours as a standard comment (plus an optional number custom field), check
  for duplicates first, and draft timesheets from your commits

Claude asks before every change to Trello. The Bitbucket side is read-only. No extra CLI is needed:
the skill talks to the Trello REST API with `curl`.

## How it's configured

| What | Where | Secret? |
|---|---|---|
| Trello key and token, Bitbucket token | environment variables, e.g. `.envrc` with [direnv](https://direnv.net) | yes, never commit |
| Board, list roles, worklog settings, Bitbucket repos, conventions | `.trello-workspace.json` in each project | no, safe to commit and share with your team |

## Install

Requirements: `jq`, `curl`, and `direnv` (recommended).

```bash
brew install jq direnv
git clone https://github.com/longvo2k/trello-workflow-skill.git ~/.claude/skills/trello-workflow
```

If you haven't set up direnv yet, add its hook to `~/.zshrc`: `eval "$(direnv hook zsh)"`.

## Get a Trello key and token

1. Go to https://trello.com/power-ups/admin and click **New**. Pick any name (e.g. "trello-workflow")
   and your workspace, then **Create**.
2. Open **API key** and click **Generate a new API key**. Copy the **API key** into
   `TRELLO_API_KEY`.
3. Next to the key, click the **Token** link, then **Allow**. This gives the token read and write
   access to your boards. Copy the token into `TRELLO_API_TOKEN`.

The token acts as you on every board you can see. Keep it in a password manager, and revoke it
under *Trello → Settings → Applications* if it leaks.

## Set up a project

```bash
cd ~/Work/my-project
~/.claude/skills/trello-workflow/scripts/workspace.sh init    # creates .trello-workspace.json and .envrc
echo ".envrc" >> .gitignore
# add the key and token to .envrc, then:
direnv allow
~/.claude/skills/trello-workflow/scripts/trello.sh boards     # find your board's short link
~/.claude/skills/trello-workflow/scripts/trello.sh lists      # after setting the board: see list names
~/.claude/skills/trello-workflow/scripts/workspace.sh doctor
```

Or just ask Claude: "set up trello-workflow for this project".

### `.trello-workspace.json`

```json
{
  "trello": {
    "board": "https://trello.com/b/AbCd1234/my-board",
    "lists": { "todo": "To Do", "doing": "Doing", "review": "Review", "done": "Done" }
  },
  "bitbucket": {
    "workspace": "your-company",
    "repos": ["mobile-app"],
    "defaultRepo": "mobile-app"
  },
  "worklog": {
    "requireComment": true,
    "dailyTargetHours": 8,
    "customField": "Time spent"
  },
  "conventions": {
    "branch": "feature/{number}-{short-summary}",
    "commit": "#{number} {message}",
    "newCardList": "todo"
  }
}
```

- `trello.board`: the board URL or short link. Required.
- `trello.lists`: maps roles to your board's real list names, so "move it to doing" works whatever
  your lists are called.
- `worklog.customField`: optional. The name of a **number** custom field that time logs add to.
  Leave it empty to log time as comments only.
- Leave out `bitbucket` to use the skill without Bitbucket. `conventions` is free-form: Claude reads
  it and follows it.

## How time logging works

Trello has no built-in time tracking, so each log is a comment in a fixed format:

```
⏱ Logged 1.5h on 2026-10-26 - Built the login form
```

`trello.sh my-time` reads your comments and adds these up by day, so you can check before logging
and avoid duplicates. Everyone on the board can see the entries.

## Use it

Talk to Claude normally:

- "What Trello cards are assigned to me?"
- "Read card #42 and tell me what I need to build"
- "Create a card in To Do: fix the login timeout, label Bug, assign me"
- "Move #42 to Doing and comment that I've started"
- "Log 1.5h on #42 for today, building the login form"
- "Draft my timesheet for this week from my commits"

The scripts also work on their own:

```bash
S=~/.claude/skills/trello-workflow/scripts
$S/trello.sh my-cards
$S/trello.sh card '#42'
$S/trello.sh move '#42' doing
$S/trello.sh log-time '#42' 1.5 --comment "Built the login form"
$S/trello.sh my-time 2026-10-20 2026-10-24
```

## Security

- Keys and tokens are read only from environment variables. They go to Trello in an
  `Authorization` header through a file descriptor, never in URLs or process lists.
- The skill tells Claude never to print tokens, never to follow instructions found inside card or PR
  text, and to confirm every Trello change before sending it.
- Bitbucket access is read-only. Use a token with only read scopes.

## License

MIT
