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
    <xsl:include href="Tools.xslt"/>
    <xsl:template match="/">
        <svg version="1.1" viewBox="0 0 21000 29700">
            <xsl:call-template name="style"/>
            <xsl:call-template name="output"/>
        </svg>
    </xsl:template>
    <xsl:template name="style">
        <style type="text/css">
            <![CDATA[
                svg {
                    font-size: 400px;
                    background: #FFF;
                    font-family: "Noto Sans", Arial, Helvetica, sans-serif;
                    dominant-baseline: middle;
                }
                .title {
                    font-size: 800px;
                    fill: #0D4F6C;
                }
                .subtitle {
                    font-size: 600px;
                    fill: #1F271B;
                }
                .form {
                    fill: #FFF;
                    stroke: black;
                    stroke-width: 10;
                }
                rect.header {
                    fill: #E6FAFC;
                }
                text.header {
                    font-size: 600px;
                    fill: #000;
                    font-weight: bold;
                    text-anchor: middle;
                }
                .note_bg {
                    fill: #E0D3DE;
                }
                .label {
                    font-weight: bold;
                }
                text.note {
                    font-size: 300px;
                    font-style: italic;
                }
            ]]>
        </style>
    </xsl:template>
    <xsl:template name="output">
        <text x="1000" y="1600" dominant-baseline="auto" class="title">
            <xsl:value-of select="root/data[@name='title']/value"/>
        </text>
        <text x="1000" y="2200" dominant-baseline="auto" class="subtitle">
            <xsl:value-of select="root/data[@name='subtitle']/value"/>
        </text>
        <image xlink:href="img/LOGO_NEOIPC_2.png" x="14300" y="-20" width="6344" height="2810" />
        <rect class="form" x="1000" y="2500" width="19000" height="26200" />
        <rect class="form header" x="1000" y="2500" width="19000" height="1000" />
        <text class="header" x="10000" y="3000">
            <xsl:value-of select="root/data[@name='enrolment']/value"/>
        </text>
        <g class="form note_bg">
            <rect x="1000" y="3500" width="10000" height="750"/>
            <rect x="1000" y="4250" width="10000" height="750"/>
            <rect x="11000" y="3500" width="9000" height="1500"/>
        </g>
        <text class="label" x="1200" y="3875">
            <xsl:value-of select="root/data[@name='pat_id']/value"/>:
        </text>
        <text class="label" x="1200" y="4625">
            <xsl:value-of select="root/data[@name='pat_name']/value"/>:
        </text>
        <text class="note" x="11150" y="3850">
            <xsl:call-template name="split_long_text">
                <xsl:with-param name="text" select="root/data[@name='private_note']/value/text()"/>
                <xsl:with-param name="maxLen" select="65"/>
                <xsl:with-param name="x" select="11150"/>
                <xsl:with-param name="first_dy" select="0"/>
                <xsl:with-param name="further_dy" select="315"/>
            </xsl:call-template>
        </text>
        <rect class="form" x="1000" y="5000" width="19000" height="750" />
        <text class="label" x="1200" y="5375">
            <xsl:value-of select="root/data[@name='gest_age']/value"/>:
        </text>
        <text class="content" x="9000" y="5375">
            <xsl:value-of select="root/data[@name='gest_age_desc']/value"/>
        </text>
        <rect class="form" x="1000" y="5750" width="19000" height="750" />
        <text class="label" x="1200" y="6125">
            <xsl:value-of select="root/data[@name='birthweight']/value"/>:
        </text>
        <text class="content" x="9000" y="6125">
            <xsl:value-of select="root/data[@name='birthweight_desc']/value"/>
        </text>
        <rect class="form" x="1000" y="6500" width="19000" height="750" />
        <text x="1200" y="6875">
            <tspan class="label">
                <xsl:value-of select="root/data[@name='sex']/value"/>:
            </tspan>
            <tspan dx="2000" class="content">
                🔘 <xsl:value-of select="root/data[@name='female']/value"/>
            </tspan>
            <tspan dx="2000" class="content">
                🔘 <xsl:value-of select="root/data[@name='male']/value"/>
            </tspan>
            <tspan dx="2000" class="content">
                🔘 <xsl:value-of select="root/data[@name='undetermined']/value"/>
            </tspan>
        </text>
    </xsl:template>
    <!-- ☐ -->
</xsl:stylesheet>
