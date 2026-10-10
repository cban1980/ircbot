# The ai plugin

[contrib/plugins/ai.rb](../contrib/plugins/ai.rb) lets the bot chat with
people through an AI model. It speaks to any backend: OpenAI and
everything with an OpenAI-compatible API (Grok, OpenRouter, Groq,
Mistral, DeepSeek, Together, LM Studio, vLLM, llama.cpp ...), Anthropic
(Claude), Google Gemini and Ollama. Several backends can be set up at
once, with fallbacks.

```sh
bin/gemdrop-docker plugin install contrib/plugins/ai.rb   # loads it right away
```

## Talking to it

| You | It |
| --- | --- |
| `Linuks: what's a monad?` in a chat channel | answers in the channel, to you |
| `/msg Linuks <anything>` | a private conversation (`AI <question>` works too) |
| `!ai <question>` | the same in a channel, if the plugin has a `prefix` |
| `AIFORGET` / `AIFORGET #chan` | forgets your private conversation / the channel's (its ops and bot admins) |
| `AISTATUS` | bot admins: each backend's requests, failures, tokens, last error |
| `AITEST [backend]` | bot admins, privately: a test request, with the answer and timing |
| `HELP chat` | where and how to talk to it |

It follows the conversation: each chat channel's, including what others
say there (so "what do you think of that?" works), and each user's
private one. A conversation goes on until it goes quiet for
`forget_after_minutes` (30), then the next line starts a new one; when it
grows beyond `max_context_chars` (12,000 characters, about 3,000 tokens)
its oldest lines are forgotten. Conversations are saved in the plugin's
private data folder, so reloads, updates and restarts don't interrupt
them (`save_memory: false` keeps them in memory only).

## Setting it up

Backends live in `config.yml` (the plugin's `backends` can't be changed
with `PLUGIN SET`; see [Security](#security)). Each has a `type` and a
`model`; the rest is optional:

```yaml
plugins:
  ai:
    backend: claude                # which one answers (default: the first)
    fallback: [local]              # tried in order if it fails
    backends:
      claude:
        type: anthropic
        model: claude-sonnet-4-5
        api_key_file: anthropic.key        # instance/secret/anthropic.key
      local:
        type: ollama
        model: llama3.2
        base_url: "http://host.docker.internal:11434"
    channel_settings:              # where it talks (see Per channel)
      IRCnet:
        "#linux.se": { chat: true }
```

**API keys** go in a file in the secret folder (`instance/secret/`, next
to the pepper), readable only by you:

```sh
install -m 600 /dev/null instance/secret/anthropic.key
$EDITOR instance/secret/anthropic.key        # paste the key
```

The file is read for every request, so a new key works without a reload.
Instead of a file, `api_key_env: VARIABLE` reads it from the bot's
environment (handy with systemd's `EnvironmentFile`), and `api_key:` takes
it from `config.yml` itself (the bot then insists that the file is
private). Keys never come from IRC.

### Backend types

| `type` | Protocol | Default `base_url` | Key |
| --- | --- | --- | --- |
| `openai` | OpenAI | `https://api.openai.com/v1` | yes |
| `grok`, `xai` | OpenAI | `https://api.x.ai/v1` | yes |
| `openrouter` | OpenAI | `https://openrouter.ai/api/v1` | yes |
| `groq` | OpenAI | `https://api.groq.com/openai/v1` | yes |
| `mistral` | OpenAI | `https://api.mistral.ai/v1` | yes |
| `deepseek` | OpenAI | `https://api.deepseek.com/v1` | yes |
| `together` | OpenAI | `https://api.together.xyz/v1` | yes |
| `openai-compatible` | OpenAI | (set `base_url`, up to `/v1`) | optional |
| `lmstudio` | OpenAI | `http://localhost:1234/v1` (local) | no |
| `anthropic`, `claude` | Anthropic Messages | `https://api.anthropic.com` | yes |
| `gemini`, `google` | Gemini generateContent | `https://generativelanguage.googleapis.com` | yes |
| `ollama` | Ollama chat | `http://localhost:11434` (local) | no |

Any service with an OpenAI-compatible chat completions API works as
`openai-compatible` with its `base_url`. Model names are the provider's
own (`gpt-4o-mini`, `claude-sonnet-4-5`, `gemini-2.5-flash`, `grok-4`,
`llama3.2` ...); there are no defaults, since they change often.

### Backend settings

| Setting | Default | |
| --- | --- | --- |
| `type`, `model` | (needed) | see above |
| `base_url` | per type | the API's address; `https` unless `local` |
| `api_key_file`, `api_key_env`, `api_key` | | one of them, if the type needs a key |
| `max_tokens` | 400 | answer length limit (and cost) |
| `temperature` | the provider's | 0 to 2 |
| `timeout` | 60 | seconds to wait for an answer (5 to 300) |
| `local` | `true` for ollama/lmstudio | may reach this machine and private networks, any port, plain http |
| `headers` | | extra request headers, e.g. OpenRouter's `{ X-Title: Gemdrop }` |
| `options` | | extra request fields, passed as they are (e.g. `{ top_p: 0.9 }`, Ollama `{ keep_alive: 30m }`); can't replace the model or messages |
| `max_tokens_field` | per type | `max_tokens` or `max_completion_tokens` (OpenAI's newer models need the latter; `openai` uses it) |

### A model on your own machine

In Docker, `localhost` is the bot's container. The container knows this
machine as `host.docker.internal`, so use
`base_url: "http://host.docker.internal:11434"` for Ollama, and make
Ollama listen on more than loopback (`OLLAMA_HOST=0.0.0.0`, or the Docker
bridge address `172.17.0.1`). Without Docker, the defaults work as they are. If the bot still can't
reach it, a firewall on this machine may block containers from its ports
(`AITEST` then times out); allow the Docker bridge to the model's port.

## Searching the channel's history

With a `search_backend`, it answers questions about what was said earlier,
also long after it dropped out of the conversation it remembers:

```
<bjorn> Linuks: vad sa anna om sin NAS igår?
<Linuks> bjorn: Hon sa att hon bytt till btrfs och att snapshots är guld.
```

The search runs over the [eventlog](eventlog.md) plugin's log of the
channel (it must be installed), in three steps:

1. The question looks like it is about the past (words like *igår*,
   *sa*, *minns*, *förra veckan*, *yesterday*, *said*, *remember*). Other
   questions are answered as usual, with no search.
2. The search backend turns the question into a search (whose lines, which
   days, which words); the bot searches the log itself (no tokens), and
   the search backend reads the best matches, each with a line around it,
   and sums up what is relevant in a few sentences.
3. That summary goes to the backend that answers, with the conversation.
   If nothing was found, it is told so, and says so instead of guessing.

Use a small, fast model with a quota of its own, so searches don't use up
the answering model's. Groq counts each model separately, so with the
same key:

```yaml
    search_backend: groq-small
    backends:
      groq-small: { type: groq, model: openai/gpt-oss-20b, api_key_file: groq.key, options: { reasoning_effort: low } }
```

A search costs the search backend about 500 tokens in two short requests,
and the answering backend about 100. Only the channel's own log is
searched, never other channels or private messages. `search: false` turns
it off for a channel, and `search_days` (30) limits how far back it looks
(the eventlog keeps 90 days by default). If the search backend fails, the
bot answers without a search.

## Behaviour settings

All can be changed live with `PLUGIN SET ai <setting> <value>` (per
network) or under `network_settings:`.

| Setting | Default | |
| --- | --- | --- |
| `chat` | `false` | talks in a channel; set it per channel (below). `true` at the top: in every channel on every network |
| `chat_private` | `true` | answer `AI <question>` by private message |
| `allowed` | `anyone` | or `identified` (a bot account) or `admins` |
| `mention_anywhere` | `false` | also answer lines that name it anywhere, not only `Nick: ...` |
| `language` | `""` | the language it answers in, e.g. `Swedish`; empty: the one it is spoken to in |
| `instructions` | `""` | how to behave, on top of the persona: the channel's topic, tone, rules ("Answer Linux questions; be patient with beginners"). Per channel, it's the best place for what makes each channel different. `%{nick}`, `%{channel}`, `%{network}` are filled in |
| `persona` | a friendly regular | who it is; `%{nick}`, `%{channel}`, `%{network}` are filled in. The plugin adds the IRC ground rules (plain text, short, can't take actions) |
| `listen` | `true` | use channel lines not addressed to it as context; `false` sends only questions to it and its answers |
| `forget_after_minutes` | 30 | a conversation ends after this long without new lines (1 to 10080) |
| `max_context_chars` | 12000 | a conversation's size; its oldest lines are forgotten beyond this (and it's what each answer costs) |
| `history_lines` | 200 | and at most this many lines |
| `save_memory` | `true` | keep conversations across reloads and restarts (`data/plugins/<network>/ai/`); `false`: in memory only |
| `max_input_chars` | 500 | longer questions are refused |
| `max_reply_lines` | 3 | lines per answer (cut with `...`) |
| `max_line_bytes` | 400 | long lines are wrapped |
| `max_mentions` | 3 | answers that name more people in the channel are dropped (mass highlights get bots banned) |
| `user_per_minute` | 4 | questions per user (by host) |
| `channel_per_minute` | 10 | answers per conversation |
| `per_hour` | 120 | answers per network in all (cost cap) |
| `ignore_nicks` | `[]` | e.g. other bots, so they don't talk in circles |
| `error_reply` | "Sorry, my brain isn't answering right now." | said when every backend fails; `""` for silence |
| `search_backend` | none | a backend that searches the channel's log (see above) |
| `search` | `true` | search for questions about the past (with `search_backend`); per channel |
| `search_days` | 30 | how far back searches look (1 to 365) |
| `log_text` | `false` | log answers (debug level); otherwise only sizes and timing are logged |
| `backend`, `fallback` | | which backend answers, and the order to try others in |

Switch the backend live with `PLUGIN SET ai backend local`.

### Per channel

Everything about a channel goes under `channel_settings`: whether it
talks there (`chat`), and `instructions`, `language`, `persona`,
`backend`, `fallback`, `allowed`, `mention_anywhere`, `listen`,
`forget_after_minutes`, `history_lines`, the `max_*` settings,
`channel_per_minute` and `error_reply`. The backends are
configured once, for every network; `backend` is the default, and a
channel can pick another:

```yaml
plugins:
  ai:
    backend: groq                      # the default, everywhere
    fallback: [gemini]
    language: English
    backends:
      groq:   { type: groq, model: openai/gpt-oss-120b, api_key_file: groq.key, options: { reasoning_effort: low } }
      gemini: { type: gemini, model: gemini-3.5-flash-lite, api_key_file: gemini.key }
    channel_settings:
      IRCnet:                                    # IRCnet's channels
        "#linux.se":
          chat: true
          language: Swedish
          instructions: >-
            This is a Swedish Linux channel. Help with Linux questions,
            give exact commands, and be patient with beginners.
      EFnet:                                     # EFnet's channels
        "#gunnit": { chat: true, max_reply_lines: 2 }
        "#linux.se": { chat: true, language: Finnish }
```

A plain `"#chan"` entry applies to that channel on every network; one
under a network's name only there, and it wins over the plain one.
Private chats use the plugin's own values.

Or live: `PLUGIN SET ai #gunnit chat true` or `PLUGIN SET ai #linux.se
backend gemini`, sent on the network it is for, saves it for that
network's channel (`PLUGIN UNSET ai
#linux.se backend` goes back to `config.yml`'s value).

## Security

- **What it sends.** Questions, and with `listen` the channel's recent
  lines, go to the backend's provider. Say so in the channel if that
  matters there; `HELP chat` tells users. Lines that look like password
  commands are never remembered or sent.
- **Keys stay put.** `backends` (where keys are sent) can only be set in
  `config.yml`, so a stolen admin login can't point a backend at another
  server to collect the key; a value saved with `PLUGIN SET` is refused,
  and ignored if one was saved anyway. Keys are only sent over https
  (or to `local` backends), never in URLs, and are cut out of error
  messages. `PLUGIN SETTINGS` and the logs hide them.
- **Requests** go through the bot's guarded HTTP client: no redirects
  (an API that redirects gets nothing), a time limit, a 1 MiB answer
  limit, and only public addresses unless the backend is `local`.
- **Answers** are cleaned before they are said: no control or formatting
  characters (so no CTCP), no Markdown, no `<think>` reasoning, at most
  `max_reply_lines` lines, and none that name more than `max_mentions`
  people in the channel.
- **Prompt injection** ("ignore your instructions and ...") can change
  what it says, but it can only talk: it has no commands, modes or
  tools, and its own lines are never taken as commands by the bot.
- **Cost** is bounded by the rate limits, `max_tokens`,
  `max_context_chars`, `max_input_chars` and one request at a time per
  conversation. `AISTATUS` shows token use since the plugin loaded.
