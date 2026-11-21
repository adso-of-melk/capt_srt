# CHunspell

Hunspell 1.7.2 (https://github.com/hunspell/hunspell, tag v1.7.2), the spell-checking
engine used by LibreOffice, Firefox and Chrome, built into KPTN.SUB for the languages macOS
doesn't check (Croatian, Serbian, Bosnian, Persian, Thai...).

Hunspell is offered under MPL 1.1, GPL 2.0 or LGPL 2.1; KPTN.SUB uses it under the
**MPL 1.1** (COPYING.MPL). Its MySpell-derived parts carry the licence in license.myspell.
The source files are unchanged copies of `src/hunspell/` from that release; only the C
interface (`hunspell.h`, `hunvisapi.h`) sits in `include/` so Swift can import it.
Built with HUNSPELL_STATIC defined.

Dictionaries are not part of the app. See scripts/fetch-dictionaries.sh.
