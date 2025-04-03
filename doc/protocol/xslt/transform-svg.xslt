<xsl:stylesheet
  version="1.0"
  xmlns="http://www.w3.org/2000/svg"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:svg="http://www.w3.org/2000/svg"
  xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  xmlns:cc="http://creativecommons.org/ns#"
  xmlns:dc="http://purl.org/dc/elements/1.1/">

  <xsl:param name="localeName" select="''"/>
  <xsl:param name="resourceBaseName" select="''"/>
  <xsl:param name="resourcePath" select="'./'"/>
  <xsl:param name="debugLevel" select="'0'"/>
  <xsl:output
      method="xml"
      version="1.0"
      encoding="UTF-8"
      doctype-public="-//W3C//DTD SVG 1.1//EN"
      doctype-system="http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"
      cdata-section-elements="style"
  />

  <!-- Create a normalized version of the resource path -->
  <xsl:variable name="normalizedResourcePath">
    <xsl:call-template name="normalize-path">
      <xsl:with-param name="input" select="$resourcePath"/>
    </xsl:call-template>
  </xsl:variable>

  <xsl:variable name="debugLevelValue" select="number($debugLevel)"/>
  <xsl:variable name="exactMatchDoc" select="document(concat($normalizedResourcePath, '/', $resourceBaseName, '.', $localeName, '.resx'))"/>
  <xsl:variable name="neutralCultureDoc" select="document(concat($normalizedResourcePath, '/', $resourceBaseName, '.', substring-before($localeName, '-'), '.resx'))"/>

  <!-- Template for copying non-text elements -->
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

 <!-- Template for localizing text elements -->
  <xsl:template match="node()[@svg:data-localisation-id or @data-localisation-id or @id]">
    <xsl:call-template name="print-debug">
      <xsl:with-param name="message">Hit template matching 'node()[@data-localisation-id or @id]' with node named '<xsl:value-of select ="name()"/>'</xsl:with-param>
      <xsl:with-param name="level">3</xsl:with-param>
    </xsl:call-template>

    <xsl:variable name="elementId">
      <xsl:choose>
        <!-- Try to get the data-localisation-id attribute value if it exists -->
        <xsl:when test="@data-localisation-id">
          <xsl:value-of select="@data-localisation-id" />
          <xsl:call-template name="print-debug">
            <xsl:with-param name="message">Element named '<xsl:value-of select ="name()"/>' has 'data-localisation-id' attribute with value '<xsl:value-of select ="@data-localisation-id"/>'</xsl:with-param>
            <xsl:with-param name="level">4</xsl:with-param>
          </xsl:call-template>
        </xsl:when>
        <!-- Try to get the data-localisation-id attribute value if it exists -->
        <xsl:when test="@svg:data-localisation-id">
          <xsl:value-of select="@svg:data-localisation-id" />
          <xsl:call-template name="print-debug">
            <xsl:with-param name="message">Element named '<xsl:value-of select ="name()"/>' has 'svg:data-localisation-id' attribute with value '<xsl:value-of select ="@data-localisation-id"/>'</xsl:with-param>
            <xsl:with-param name="level">4</xsl:with-param>
          </xsl:call-template>
        </xsl:when>
        <!-- Fall back to the id attribute value if no data-localisation-id attribute is found -->
        <xsl:when test="@id">
          <xsl:value-of select="@id" />
          <xsl:call-template name="print-debug">
            <xsl:with-param name="message">Element named '<xsl:value-of select ="name()"/>' has 'id' attribute with value '<xsl:value-of select ="@id"/>'</xsl:with-param>
            <xsl:with-param name="level">3</xsl:with-param>
          </xsl:call-template>
        </xsl:when>
      </xsl:choose>
    </xsl:variable>
    <xsl:call-template name="print-debug">
      <xsl:with-param name="message">Value of variable 'elementId' is '<xsl:value-of select ="$elementId"/>'</xsl:with-param>
      <xsl:with-param name="level">2</xsl:with-param>
    </xsl:call-template>

    <xsl:variable name="localizedString">
      <xsl:choose>
        <xsl:when test="$exactMatchDoc//data[@name=$elementId]/value">
          <xsl:value-of select ="normalize-space($exactMatchDoc//data[@name=$elementId]/value)"/>
        </xsl:when>
        <xsl:when test="$neutralCultureDoc//data[@name=$elementId]/value">
          <xsl:value-of select ="normalize-space($neutralCultureDoc//data[@name=$elementId]/value)"/>
        </xsl:when>
      </xsl:choose>
    </xsl:variable>

    <!-- Check for a non-empty localized string -->
    <xsl:choose>
      <xsl:when test="$localizedString != ''">
        <xsl:call-template name="print-debug">
          <xsl:with-param name="message">Value of variable 'localizedString' is '<xsl:value-of select ="$localizedString"/>'</xsl:with-param>
        </xsl:call-template>
        <xsl:variable name="maxLength">
          <xsl:choose>
            <xsl:when test="@data-localisation-max-length">
              <xsl:value-of select="@data-localisation-max-length" />
            </xsl:when>
            <xsl:when test="@svg:data-localisation-max-length">
              <xsl:value-of select="@svg:data-localisation-max-length" />
            </xsl:when>
          </xsl:choose>
        </xsl:variable>
        <xsl:variable name="dy">
          <xsl:choose>
            <xsl:when test="@data-localisation-heigth">
              <xsl:value-of select="@data-localisation-heigth" />
            </xsl:when>
            <xsl:when test="@svg:data-localisation-heigth">
              <xsl:value-of select="@svg:data-localisation-heigth" />
            </xsl:when>
            <xsl:otherwise>9</xsl:otherwise>
          </xsl:choose>
        </xsl:variable>
        <xsl:copy>
          <xsl:for-each select="@*">
            <xsl:if test="local-name() != 'data-localisation-id' and local-name() != 'data-localisation-max-length'  and local-name() != 'data-localisation-heigth' and name() != 'id'"><xsl:attribute name="{name()}"><xsl:value-of select="."/></xsl:attribute></xsl:if>
          </xsl:for-each>
          <xsl:choose>
            <xsl:when test="$maxLength != ''">
              <xsl:call-template name="print-debug">
                <xsl:with-param name="message">Maximum length is <xsl:value-of select ="$maxLength"/></xsl:with-param>
              </xsl:call-template>
              <xsl:call-template name="split_long_text">
                <xsl:with-param name="text" select="$localizedString"/>
                <xsl:with-param name="maxLen" select="$maxLength"/>
                <xsl:with-param name="x" select="@x"/>
                <xsl:with-param name="dy" select="$dy"/>
              </xsl:call-template>
            </xsl:when>
            <xsl:otherwise>
              <xsl:value-of select="$localizedString" />
            </xsl:otherwise>
          </xsl:choose>
        </xsl:copy>
      </xsl:when>
      <xsl:otherwise>
        <xsl:copy>
          <xsl:apply-templates select="@*|node()"/>
        </xsl:copy>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Replace dc:language with the value of the variable -->
  <xsl:template match="dc:language">
    <xsl:element name="dc:language">
      <xsl:value-of select="$localeName"/>
    </xsl:element>
  </xsl:template>
  
  <!-- Remove width and height attributes from the svg element -->
  <xsl:template match="@width | @height">
    <xsl:choose>
      <xsl:when test="local-name(..) = 'svg'">
        <xsl:call-template name="print-debug">
          <xsl:with-param name="message">Removing <xsl:value-of select ="name()"/> attribute from the svg.</xsl:with-param>
          <xsl:with-param name="level">4</xsl:with-param>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <xsl:call-template name="print-debug">
          <xsl:with-param name="message">Found <xsl:value-of select ="name()"/> attribute with value '<xsl:value-of select ="."/>' in <xsl:value-of select ="name(..)"/> element.</xsl:with-param>
          <xsl:with-param name="level">4</xsl:with-param>
        </xsl:call-template>
        <xsl:attribute name="{name()}"><xsl:value-of select="."/></xsl:attribute>
      </xsl:otherwise>
    </xsl:choose>
 </xsl:template>

  <!-- Remove id attributes from elements that are not in a <defs> context -->
  <xsl:template match="//*[@id and not(name(..) = 'defs')]/@id">
     <xsl:call-template name="print-debug">
      <xsl:with-param name="message">Removing id attribute with value '<xsl:value-of select ="."/>' from <xsl:value-of select ="name(..)"/> element.</xsl:with-param>
      <xsl:with-param name="level">4</xsl:with-param>
    </xsl:call-template>
 </xsl:template>

  <!-- Remove elements and attributes from the "inkscape" namespace -->
  <xsl:template match="*[namespace-uri()='http://www.inkscape.org/namespaces/inkscape']"/>
  <xsl:template match="@*[starts-with(name(), 'inkscape:')]"/>

  <!-- Remove elements and attributes from the "sodipodi" namespace -->
  <xsl:template match="*[namespace-uri()='http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd']"/>
  <xsl:template match="@*[starts-with(name(), 'sodipodi:')]"/>

  <!-- Remove comments -->
  <xsl:template match="comment()"/>

  <xsl:template name="split_long_text">
    <xsl:param name="text"/>
    <xsl:param name="separator" select="' '"/>
    <xsl:param name="maxLen"/>
    <xsl:param name="x"/>
    <xsl:param name="first_dy" select="0"/>
    <xsl:param name="dy"/>
    <xsl:param name="previous"/>
    <xsl:choose>
      <xsl:when test="(string-length($previous) &gt; 0) and not(contains($text, $separator)) and (string-length(concat($previous, ' ', $text)) &lt; $maxLen)">
        <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="concat($previous, ' ', $text)"/></tspan>
      </xsl:when>
      <xsl:when test="(string-length($previous) &gt; 0) and not(contains($text, $separator))">
        <tspan x="{$x}" dy="{$first_dy}"><xsl:value-of select="$previous"/></tspan>
        <tspan x="{$x}" dy="{$dy}"><xsl:value-of select="$text"/></tspan>
      </xsl:when>
      <xsl:when test="(string-length($previous) &gt; 0) and (string-length(concat($previous, ' ', substring-before($text, $separator))) &lt; $maxLen)">
        <xsl:call-template name="split_long_text">
          <xsl:with-param name="text" select="substring-after($text, $separator)"/>
          <xsl:with-param name="separator" select="$separator"/>
          <xsl:with-param name="maxLen" select="$maxLen"/>
          <xsl:with-param name="x" select="$x"/>
          <xsl:with-param name="first_dy" select="$first_dy"/>
          <xsl:with-param name="dy" select="$dy"/>
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
          <xsl:with-param name="first_dy" select="$dy"/>
          <xsl:with-param name="dy" select="$dy"/>
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
          <xsl:with-param name="dy" select="$dy"/>
          <xsl:with-param name="previous" select="substring-before($text, $separator)"/>
        </xsl:call-template>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Recursive template to remove trailing '/' characters and replace '\' with '/' -->
  <xsl:template name="normalize-path">
    <xsl:param name="input"/>
    <xsl:choose>
      <xsl:when test="substring($input, string-length($input)) = '/'">
        <!-- Remove the last character and recurse -->
        <xsl:call-template name="normalize-path">
          <xsl:with-param name="input" select="substring($input, 1, string-length($input) - 1)"/>
        </xsl:call-template>
      </xsl:when>
      <xsl:otherwise>
        <!-- Return the trimmed string -->
        <xsl:value-of select="translate($input, '\', '/')"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Template to conditionally print debug messages -->
  <xsl:template name="print-debug">
    <xsl:param name="message"/>
    <xsl:param name="level" select="1"/>
    <xsl:if test="$debugLevelValue >= $level">
      <xsl:message terminate="no">DEBUG <xsl:value-of select ="$level"/>: <xsl:value-of select ="$message"/></xsl:message>
    </xsl:if>
  </xsl:template>

</xsl:stylesheet>
