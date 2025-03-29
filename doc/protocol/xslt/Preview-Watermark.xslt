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
    <xsl:template match="/">
        <svg version="1.1" viewBox="0 0 21000 29700">
            <text transform="translate(10500, 14850) rotate(-45)" text-anchor="middle" dominant-baseline="central" font-family="&quot;Noto Sans&quot;,Arial,Helvetica,sans-serif" font-size="2550px" font-weight="900" opacity="0.3">
                <xsl:choose>
                    <xsl:when test="root/data[@name='preview']/value">
                            <xsl:value-of select="root/data[@name='preview']/value"/>
                    </xsl:when>
                    <xsl:otherwise>Preview Version</xsl:otherwise>
                </xsl:choose>
            </text>
        </svg>
    </xsl:template>
</xsl:stylesheet>
