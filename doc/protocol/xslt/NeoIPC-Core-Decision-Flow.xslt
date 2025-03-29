<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns="http://www.w3.org/2000/svg" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
    <xsl:output method="xml" cdata-section-elements="style"/>
    <xsl:output method="xml" encoding="utf-8" indent="yes" cdata-section-elements="style" omit-xml-declaration="yes"/>
    <xsl:template match="/">
        <svg version="1.1" viewBox="0 0 1567 967">
            <style type="text/css">
                <![CDATA[
                    text {
                        font-size: 35px;
                        font-family: Noto Sans, sans-serif;
                        dominant-baseline: middle;
                        text-anchor: middle;
                    }
                    .emphasize {
                        text-transform: uppercase;
                        font-weight: bold;
                    }
                    path.arrow {
                        stroke: black;
                        stroke-width: 2;
                        fill: none;
                        marker-end: url(#arrow);
                    }
                    text.white {
                        fill: white;
                    }
                    rect.condition {
                        stroke: #344E6D;
                        stroke-width: 4;
                        fill: #0070C0;
                        rx: 20;
                    }
                    rect.choice {
                        stroke: black;
                        stroke-width: 2;
                    }
                    rect.bigfalse {
                        fill: #FADBB5;
                    }
                    rect.false {
                        fill: #000000;
                    }
                    rect.true {
                        fill: #FFFFFF;
                    }
                    ellipse.ineligible {
                        stroke: #C00000;
                        stroke-width: 4;
                        fill: #FF0000;
                    }
                    circle.eligible {
                        stroke: #536142;
                        stroke-width: 4;
                        fill: #92D050;
                    }
                ]]>
            </style>
            <defs>
                <marker
                style="overflow:visible"
                id="arrow"
                refX="4"
                refY="0"
                orient="auto"
                markerWidth="10"
                markerHeight="9"
                preserveAspectRatio="none">
                <path d="M -2,-4 9,0 -2,4 c 2,-2.33 2,-5.66 0,-8 z"/>
                </marker>
            </defs>
            <rect fill="white" width="1567" height="967"/>
            <rect x="350" y="12" width="644" height="130" class="condition"/>
            <text x="672" y="58" class="white">
                <xsl:call-template name="split_long_text">
                    <xsl:with-param name="text" select="root/data[@name='admitted']/value/text()"/>
                    <xsl:with-param name="maxLen" select="38"/>
                    <xsl:with-param name="x" select="672"/>
                    <xsl:with-param name="first_dy" select="0"/>
                    <xsl:with-param name="further_dy" select="39"/>
                </xsl:call-template>
            </text>
            <path d="M348,77 L159,77 159,840 380,840" class="arrow"/>
            <rect x="12" y="252" width="293" height="370" class="choice bigfalse"/>
            <text x="159" y="341">
                <tspan dx="0" dy="0" class="emphasize"><xsl:value-of select="root/data[@name='no']/value"/></tspan>
                <xsl:call-template name="split_long_text">
                    <xsl:with-param name="text" select="root/data[@name='not_admitted']/value/text()"/>
                    <xsl:with-param name="maxLen" select="16"/>
                    <xsl:with-param name="x" select="159"/>
                    <xsl:with-param name="first_dy" select="39"/>
                    <xsl:with-param name="further_dy" select="39"/>
                </xsl:call-template>
            </text>
            <path d="M672,144 L672,244" class="arrow"/>
            <rect x="611" y="166" width="125" height="56" class="choice true"/>
            <text x="672" y="200" class="emphasize"><xsl:value-of select="root/data[@name='yes']/value"/></text>
            <rect x="387" y="252" width="570" height="130" class="condition"/>
            <text x="672" y="317" class="white"><xsl:value-of select="root/data[@name='gestational_age']/value"/></text>
            <path d="M957,317 L1206,317" class="arrow"/>
            <rect x="1017" y="289" width="125" height="56" class="choice true"/>
            <text x="1079" y="323" class="emphasize"><xsl:value-of select="root/data[@name='yes']/value"/></text>
            <circle cx="1365" cy="434" r="190" class="eligible"/>
            <text x="1365" y="414" class="white emphasize">
                <tspan x="1365" dy="0" style="font:icon">☑</tspan>
                <tspan x="1365" dy="39"><xsl:value-of select="root/data[@name='eligible']/value"/></tspan>
            </text>
            <path d="M672,384 L672,484" class="arrow"/>
            <rect x="611" y="406" width="125" height="56" class="choice false"/>
            <text x="672" y="440" class="emphasize white"><xsl:value-of select="root/data[@name='no']/value"/></text>
            <rect x="387" y="492" width="570" height="130" class="condition"/>
            <text x="672" y="557" class="white"><xsl:value-of select="root/data[@name='birthweight']/value"/></text>
            <path d="M957,557 L1210,557" class="arrow"/>
            <rect x="1017" y="529" width="125" height="56" class="choice true"/>
            <text x="1079" y="563" class="emphasize"><xsl:value-of select="root/data[@name='yes']/value"/></text>
            <path d="M672,624 L672,724" class="arrow"/>
            <rect x="611" y="646" width="125" height="56" class="choice false"/>
            <text x="672" y="680" class="emphasize white"><xsl:value-of select="root/data[@name='no']/value"/></text>
            <ellipse cx="672" cy="840" rx="285" ry="108" class="ineligible"/>
            <text x="672" y="820" class="white emphasize">
                <tspan x="672" dy="0" style="font:icon">☐</tspan>
                <tspan x="672" dy="39"><xsl:value-of select="root/data[@name='ineligible']/value"/></tspan>
            </text>
        </svg>
    </xsl:template>
    <xsl:template match="root/data[@name='not_admitted']/value/text()" name="split_long_text">
        <xsl:param name="text" select="."/>
        <xsl:param name="separator" select="' '"/>
        <xsl:param name="maxLen"/>
        <xsl:param name="x"/>
        <xsl:param name="first_dy"/>
        <xsl:param name="further_dy"/>
        <xsl:param name="previous"/>
        <xsl:choose>
            <xsl:when test="(string-length($previous) &gt; 0) and not(contains($text, $separator)) and (string-length(concat($previous, ' ', $text)) &lt; $maxLen)">
                <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="concat($previous, ' ', $text)"/></tspan>
            </xsl:when>
            <xsl:when test="(string-length($previous) &gt; 0) and not(contains($text, $separator))">
                <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="$previous"/></tspan>
                <tspan x="{$x}" dy="{$further_dy}"><xsl:value-of select="$text"/></tspan>
            </xsl:when>
            <xsl:when test="(string-length($previous) &gt; 0) and (string-length(concat($previous, ' ', substring-before($text, $separator))) &lt; $maxLen)">
                <xsl:call-template name="split_long_text">
                    <xsl:with-param name="text" select="substring-after($text, $separator)"/>
                    <xsl:with-param name="separator" select="$separator"/>
                    <xsl:with-param name="maxLen" select="$maxLen"/>
                    <xsl:with-param name="x" select="$x"/>
                    <xsl:with-param name="first_dy" select="$first_dy"/>
                    <xsl:with-param name="further_dy" select="$further_dy"/>
                    <xsl:with-param name="previous" select="concat($previous, ' ', substring-before($text, $separator))"/>
                </xsl:call-template>
            </xsl:when>
            <xsl:when test="string-length($previous) &gt; 0">
                <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="$previous"/></tspan>
                <xsl:call-template name="split_long_text">
                    <xsl:with-param name="text" select="substring-after($text, $separator)"/>
                    <xsl:with-param name="separator" select="$separator"/>
                    <xsl:with-param name="maxLen" select="$maxLen"/>
                    <xsl:with-param name="x" select="$x"/>
                    <xsl:with-param name="first_dy" select="$further_dy"/>
                    <xsl:with-param name="further_dy" select="$further_dy"/>
                    <xsl:with-param name="previous" select="substring-before($text, $separator)"/>
                </xsl:call-template>
            </xsl:when>
            <xsl:when test="not(contains($text, $separator)) or (string-length(substring-before($text, $separator)) &gt; $maxLen)">
                <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="$text"/></tspan>
            </xsl:when>
            <xsl:otherwise>
                <xsl:call-template name="split_long_text">
                    <xsl:with-param name="text" select="substring-after($text, $separator)"/>
                    <xsl:with-param name="separator" select="$separator"/>
                    <xsl:with-param name="maxLen" select="$maxLen"/>
                    <xsl:with-param name="x" select="$x"/>
                    <xsl:with-param name="first_dy" select="$first_dy"/>
                    <xsl:with-param name="further_dy" select="$further_dy"/>
                    <xsl:with-param name="previous" select="substring-before($text, $separator)"/>
                </xsl:call-template>
            </xsl:otherwise>
        </xsl:choose>
    </xsl:template>
</xsl:stylesheet>
