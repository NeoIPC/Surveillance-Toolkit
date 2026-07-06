# Licensing

The content in this directory is compiled from two WHO upstream sources, each with its own copyright and license terms. Full citations and source URLs are in [`README.md`](README.md).

While the repository as a whole is licensed under the [MIT License](https://spdx.org/licenses/MIT.html), we cannot relicense the upstream content under terms that conflict with the licenses chosen by its authors. The effective license for this directory is therefore the strictest of the applicable upstream licenses: the Creative Commons [Attribution-NonCommercial-NoDerivatives 4.0 International (CC BY-NC-ND 4.0)](https://creativecommons.org/licenses/by-nc-nd/4.0/) license.

The two sources pull in different directions, and the stricter one governs:

- The `aware_category` assignments come from the WHO [AWaRe classification of antibiotics, 2021](https://www.who.int/publications/i/item/2021-aware-classification) (WHO/MHP/HPS/EML/2021.04), licensed [CC BY-NC-SA 3.0 IGO](https://creativecommons.org/licenses/by-nc-sa/3.0/igo/) — non-commercial, but derivatives are permitted under its share-alike terms.
- The substance names, ATC codes, and ATC group names/descriptions derive from the WHO Collaborating Centre for Drug Statistics Methodology [ATC/DDD index](https://www.whocc.no/) and are reproduced unchanged under the ATC/DDD [copyright and disclaimer](https://atcddd.fhi.no/copyright_disclaimer/), which permit **neither commercial use nor modification** of the classification.

Because the ATC/DDD terms are no-derivatives — stricter than the AWaRe share-alike license — the directory as a whole is effectively no-derivatives, i.e. CC BY-NC-ND 4.0. This floor is dictated by the upstream terms, not a restriction NeoIPC chose to add. The translations we ship are added localizations, not alterations of the classification.
