# Extra dictionary words

`<code>.extra.dic` adds words that a language's Hunspell dictionary is missing. Each line is a
headword with the main dictionary's affix flags, so every form comes with it: `faliti/56`
(conjugated like `hvaliti`) also accepts *fali, falim, falio, falila…*; `plahiji/355` (like
`hrabriji`) also accepts *plahija, najplahiji…*. The first line is the number of words.

To find the flag for a new word, look up a word that inflects the same way in `<code>.dic`
and copy its flag. A word with no flag is accepted only exactly as written.

`scripts/fetch-dictionaries.sh` copies these into the Dictionaries folder and
`scripts/package-app.sh` bundles them in the app. KPTN.SUB loads every `<code>.extra.dic`
it finds (in the Dictionaries folder and in the app) on top of the main dictionary.
