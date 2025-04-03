<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns="http://www.w3.org/2000/svg" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:xlink="http://www.w3.org/1999/xlink">
    <xsl:output
        method="xml"
        version="1.0"
        encoding="UTF-8"
        doctype-public="-//W3C//DTD SVG 1.1//EN"
        doctype-system="http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"
        indent="yes"
        cdata-section-elements="style"
    />
    <xsl:include href="NeoIPC-Core-Master-Data-Collection-Sheet.xslt"/>
    <xsl:template match="/">
        <svg version="1.1" viewBox="0 0 21200 29900">
            <defs>
                <filter id="shadow">
                    <feDropShadow dx="100" dy="100" stdDeviation="100" />
                </filter>
                <symbol id="form" viewBox="0 0 21000 29700">
                    <xsl:call-template name="output"/>
                </symbol>
            </defs>
            <xsl:call-template name="style"/>
            <rect x="100" y="100" fill="white" stroke="black" style="filter:url(#shadow);" width="21000" height="29700"/>
            <use xlink:href="#form" x="100" y="100" width="21000" height="29700"/>
        </svg>
    </xsl:template>
</xsl:stylesheet>
