# HandyTextReplacements

A Hammerspoon Spoon that post-processes Handy transcriptions before pasting
them. It supports spoken punctuation, whitespace cleanup, capitalization, and
multiple spoken aliases for one replacement.

## Install

Download `HandyTextReplacements.spoon.zip` from the latest GitHub release, then
run:

```sh
ditto -x -k HandyTextReplacements.spoon.zip ~/.hammerspoon/Spoons
```

Add this to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("HandyTextReplacements")
spoon.HandyTextReplacements:start()
```

Reload Hammerspoon with `hs -c 'hs.reload()'`.

## Configure

- Reload settings: `spoon.HandyTextReplacements:reload()`
- Configure Handy: `spoon.HandyTextReplacements:configureHandy()`
- Run tests: `spoon.HandyTextReplacements:runTests()`
- Process text: `spoon.HandyTextReplacements:process("open bracket test close bracket period")`
- Open settings: `open ~/.hammerspoon/Spoons/HandyTextReplacements.spoon/config.json`
- Open replacements: `open ~/.hammerspoon/Spoons/HandyTextReplacements.spoon/replacements.json`

Give one rule multiple spoken aliases by making `search` an array:

```json
{
  "search": ["closed paren", "close paren", "close Perrin"],
  "replace": ")"
}
```
