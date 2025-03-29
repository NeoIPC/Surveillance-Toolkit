# Antibiotics

## List of Antibiotics

The list of antibiotics in `NeoIPC-Antibiotics.csv` and the associated translation files (`NeoIPC-Antibiotics.`*`LOCALE`*`.csv`) are used to generate the list of options for selecting an antibiotic in NeoIPC.
It is based on information provided by the [WHO Collaborating Centre for Drug Statistics Methodology, Oslo, Norway](https://www.whocc.no/) and uses the ATC-code as code.
Currently the list contains a subset of the J01 (antibacterials for systemic use) branch with the combination products removed.

Since NeoIPC cares about antibiotic substances rather than the products containing antibiotic substances, the question whether the actual product might contain other active ingredients is not considered as relevant.
While keeping combination products (e.g., J01CA51 "ampicillin, combinations") as they are in the ATC index could theoretically be feasible, they tend to confuse people and decrease the quality of the collected data without increasing the resolution of information in the domain of antibiotic resistance.
Most of the time these combinations get selected where an antibiotic is used in combination with another antibiotic (combination therapy) rather than when a product containing an antibiotic and one or more other active ingredients is chosen.

## WHO AWaRe Classification

<https://www.who.int/publications/i/item/2021-aware-classification>

WHO Access, Watch, Reserve (AWaRe) classification of antibiotics for evaluation and monitoring of use, 2021. Geneva: World Health Organization; 2021 (WHO/MHP/HPS/EML/2021.04). Licence: [CC BY-NC-SA 3.0 IGO](https://creativecommons.org/licenses/by-nc-sa/3.0/igo/).
