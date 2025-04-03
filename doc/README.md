# Building the NeoIPC documentation

If you want to build the NeoIPC documentation from this repository with all features you need the following software:

* [PowerShell](https://learn.microsoft.com/de-de/powershell/)
* [Asciidoctor PDF](https://docs.asciidoctor.org/pdf-converter/latest/)
* [Pandoc](https://pandoc.org/)
* [rsvg-convert](https://github.com/GNOME/librsvg/blob/main/rsvg-convert.rst)
* The [Noto Sans](https://fonts.google.com/noto/specimen/Noto+Sans) Font

## Installing the tools

### Windows

#### Powershell

If you don't have a modern version of PowerShell on your system, start by installing one from <https://github.com/PowerShell/powershell/releases>.

#### Chocolatey

Next you probably want to install Chocolatey as described at <https://chocolatey.org/install#individual>.

While there are other ways to install the required tools, this is currently the easiest way.

#### Ruby, Node.js, Pandoc and rsvg-convert

Once you have successfully installed Chocolatey you can install Ruby, Pandoc and rsvg-convert in one go by issuing the following command from a [console with adminitrative privileges](https://www.howtogeek.com/194041/how-to-open-the-command-prompt-as-administrator-in-windows-10/):

```console
choco install ruby nodejs.install pandoc rsvg-convert
```

#### LintHTML

LintHTML is a Node.js package with a command line to lint HTML.
Install it (globally) via the following coomand. 

```console
npm install -g @linthtml/linthtml
```

#### Asciidoctor PDF

Since Asciidoctor PDF is a Ruby Gem it is best to install it via the common Ruby package management command line (that way you get the most recent version and all dependencies).
To do that run the following command:

```console
gem install asciidoctor-pdf
```

#### AsciiMath

The formulas in the documentation are expressed in [AsciiMath](https://asciimath.org/) syntax.
To use it we need to install the AsciiMath Gem via the following command:

```console
gem install asciimath
```

#### Noto Sans

The font can be downloaded from <https://fonts.google.com/noto/specimen/Noto+Sans>.

To install the Noto Sans font please refer to
<https://fonts.google.com/knowledge/using_type/installing_and_managing_fonts> for how to best install and manage fonts.

### Ubuntu

#### PowerShell, Ruby, Pandoc, rsvg-convert, fnt and Noto Sans

To install PowerShell via apt-get you have to add the *Linux package repository for Microsoft products* which complicates things a bit. Then again, once you have done this, the rest (including installing Google Fonts via fnt) is pretty easy.

The following commands should do the job:

````bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg wget apt-transport-https software-properties-common
sudo mkdir -p /etc/apt/keyrings
source /etc/os-release
wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
NODE_MAJOR=21
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt-get update
sudo apt-get install -y powershell ruby-full nodejs pandoc librsvg2-bin fnt bison flex libffi-dev libxml2-dev libgdk-pixbuf2.0-dev libcairo2-dev libpango1.0-dev libwebp-dev fonts-lyx
sudo gem install mathematical:1.6.18 asciidoctor-pdf asciidoctor-bibtex asciidoctor-diagram asciimath asciidoctor-mathematical
sudo npm install -g @linthtml/linthtml
sudo fnt update
sudo fnt install notosans
````
