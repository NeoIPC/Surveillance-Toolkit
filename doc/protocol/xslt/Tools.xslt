<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="1.0" xmlns="http://www.w3.org/2000/svg" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" xmlns:xlink="http://www.w3.org/1999/xlink">
    <xsl:template name="split_long_text">
        <xsl:param name="text"/>
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
