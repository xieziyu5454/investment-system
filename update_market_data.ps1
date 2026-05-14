$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outFile = Join-Path $root "market-data.js"

function Invoke-Json($url) {
  $headers = @{
    "User-Agent" = "Mozilla/5.0 InvestmentTracker/1.0"
    "Accept" = "application/json,text/plain,*/*"
  }
  $lastError = $null
  for ($i = 1; $i -le 3; $i++) {
    try {
      return Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec 45
    } catch {
      $lastError = $_
      Start-Sleep -Seconds (2 * $i)
    }
  }
  try {
    $raw = curl.exe -L --max-time 45 -A "Mozilla/5.0 InvestmentTracker/1.0" $url
    if ($LASTEXITCODE -eq 0 -and $raw) {
      return ($raw -join "`n") | ConvertFrom-Json
    }
  } catch {
    $lastError = $_
  }
  throw $lastError
}

function Get-Percentile($values, $value) {
  if (-not $values -or $values.Count -eq 0) { return $null }
  $below = @($values | Where-Object { $_ -lt $value }).Count
  $eq = @($values | Where-Object { $_ -eq $value }).Count
  return [math]::Round((($below + $eq * 0.5) / $values.Count) * 100)
}

function Convert-Kline($json) {
  @($json.data.klines) | ForEach-Object {
    $p = ([string]$_).Split(",")
    [pscustomobject]@{
      date = $p[0]
      open = [double]$p[1]
      close = [double]$p[2]
      high = [double]$p[3]
      low = [double]$p[4]
      volume = [double]$p[5]
    }
  }
}

function Get-DrawdownInfo($rows) {
  if (-not $rows -or $rows.Count -eq 0) { return $null }
  $latest = $rows[-1]
  $high = ($rows | Measure-Object -Property high -Maximum).Maximum
  [pscustomobject]@{
    date = $latest.date
    close = [double]$latest.close
    high = [double]$high
    drawdownPct = [math]::Round((([double]$latest.close - [double]$high) / [double]$high) * 100, 2)
  }
}

function Get-KeywordAssessment($items, $keywords, $strongKeywords) {
  $hits = @()
  foreach ($item in $items) {
    $text = (($item.title + " " + $item.summary) -replace "\s+", " ")
    foreach ($kw in $keywords) {
      if ($text -like "*$kw*") {
        $hits += [pscustomobject]@{ keyword = $kw; title = $item.title; url = $item.url }
        break
      }
    }
  }

  $strongHits = @()
  foreach ($item in $items) {
    $text = (($item.title + " " + $item.summary) -replace "\s+", " ")
    foreach ($kw in $strongKeywords) {
      if ($text -like "*$kw*") {
        $strongHits += [pscustomobject]@{ keyword = $kw; title = $item.title; url = $item.url }
        break
      }
    }
  }

  $score = [math]::Min(100, $hits.Count * 10 + $strongHits.Count * 20)
  [pscustomobject]@{
    score = $score
    triggered = ($hits.Count -ge 3 -or $strongHits.Count -ge 1)
    hitCount = $hits.Count
    strongHitCount = $strongHits.Count
    examples = @($hits + $strongHits | Select-Object -First 6)
  }
}

$endDate = Get-Date
$startDate = $endDate.AddMonths(-7)
$startText = $startDate.ToString("yyyyMMdd")
$endText = $endDate.ToString("yyyyMMdd")

$marginUrl = "https://datacenter-web.eastmoney.com/api/data/v1/get?reportName=RPTA_RZRQ_LSHJ&columns=ALL&source=WEB&sortColumns=DIM_DATE&sortTypes=-1&pageNumber=1&pageSize=260"
$peUrl = "https://www.csindex.com.cn/csindex-home/perf/indexCsiDsPe?indexCode=000300"
$hs300Url = "https://www.csindex.com.cn/csindex-home/perf/index-perf?indexCode=000300&startDate=$startText&endDate=$endText"
$goldUrl = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=1.518880&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61&klt=101&fqt=1&beg=$startText&end=$endText"
$etf300Url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=1.510300&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61&klt=101&fqt=1&beg=$startText&end=$endText"
$newsUrl = "https://np-listapi.eastmoney.com/comm/web/getNewsByColumns?client=web&biz=web_news_col&column=350&pageSize=80&page=1&req_trace=1"

Write-Host "Reading Eastmoney margin balance..."
$marginJson = Invoke-Json $marginUrl
$margin = @($marginJson.result.data) |
  Sort-Object DIM_DATE |
  ForEach-Object {
    [pscustomobject]@{
      date = ([datetime]$_.DIM_DATE).ToString("yyyy-MM-dd")
      value = [math]::Round(([double]$_.RZYE) / 100000000, 2)
      rawYuan = [double]$_.RZYE
    }
  }

Write-Host "Reading CSI 300 PE..."
$peJson = Invoke-Json $peUrl
$pe = @($peJson.data) |
  Sort-Object tradeDate |
  Select-Object -Last 260 |
  ForEach-Object {
    $d = [datetime]::ParseExact([string]$_.tradeDate, "yyyyMMdd", $null)
    [pscustomobject]@{
      date = $d.ToString("yyyy-MM-dd")
      value = [double]$_.peg
    }
  }

Write-Host "Reading CSI 300 price history..."
$hs300Json = Invoke-Json $hs300Url
$hs300 = @($hs300Json.data) |
  Sort-Object tradeDate |
  ForEach-Object {
    [pscustomobject]@{
      date = $_.tradeDate
      open = [double]$_.open
      close = [double]$_.close
      high = [double]$_.high
      low = [double]$_.low
    }
  }

Write-Host "Reading ETF price history..."
$gold = Convert-Kline (Invoke-Json $goldUrl)
$etf300 = Convert-Kline (Invoke-Json $etf300Url)

Write-Host "Reading news for narrative assessment..."
$newsItems = @()
try {
  $newsJson = Invoke-Json $newsUrl
  $newsItems = @($newsJson.data.list)
} catch {
  $newsItems = @()
}
$newsSince = (Get-Date).AddDays(-7)
$recentNewsItems = @($newsItems | Where-Object {
  try { ([datetime]$_.showTime) -ge $newsSince } catch { $true }
} | Select-Object -First 80 | ForEach-Object {
  [pscustomobject]@{
    showTime = $_.showTime
    mediaName = $_.mediaName
    title = $_.title
    summary = $_.summary
    url = $_.url
  }
})

$marginValues = @($margin | Select-Object -ExpandProperty value)
$peValues = @($pe | Select-Object -ExpandProperty value)
$latestMargin = $margin[-1]
$latestPe = $pe[-1]
$marginPct = Get-Percentile $marginValues $latestMargin.value
$pePct = Get-Percentile $peValues $latestPe.value
$temp = [math]::Round($marginPct * 0.7 + $pePct * 0.3)
if ($latestPe.value -lt 12) { $temp = [math]::Min($temp, 60) }
if ($latestPe.value -gt 18) { $temp = [math]::Max($temp, 40) }

$hs300Drawdown = Get-DrawdownInfo $hs300
$goldDrawdown = Get-DrawdownInfo $gold
$etf300Drawdown = Get-DrawdownInfo $etf300

$mediaKeywords = @("牛市", "全面行情", "赚钱效应", "大涨", "新高", "抢筹", "爆发", "火爆", "行情升温", "增量资金")
$mediaStrong = @("全面牛市", "牛市来了", "全民炒股", "全面行情", "赚钱效应扩散")
$socialKeywords = @("财富自由", "推荐股票", "开户", "股民", "散户", "满仓", "踏空", "刷屏", "翻倍", "冲上热搜")
$socialStrong = @("财富自由", "全民炒股", "推荐股票", "翻倍股", "开户潮")
$mediaAssessment = Get-KeywordAssessment $newsItems $mediaKeywords $mediaStrong
$socialAssessment = Get-KeywordAssessment $newsItems $socialKeywords $socialStrong

$hsBuyA = $temp -le 30
$hsBuyB = $hs300Drawdown -and $hs300Drawdown.drawdownPct -le -8
$peExtra = $latestPe.value -le 13
$hsBuyAmount = 0
if ($hsBuyA -and $hsBuyB) { $hsBuyAmount = 30000 }
elseif ($hsBuyA -or $hsBuyB) { $hsBuyAmount = 20000 }
if ($hsBuyAmount -gt 0 -and $peExtra) { $hsBuyAmount += 20000 }

$sellAssistCount = 0
if ($mediaAssessment.triggered) { $sellAssistCount += 1 }
if ($socialAssessment.triggered) { $sellAssistCount += 1 }
$hsSell = $temp -ge 80 -and $sellAssistCount -ge 1

$signals = [pscustomobject]@{
  generatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  sentiment = [pscustomobject]@{
    date = $latestMargin.date
    temperature = $temp
    marginPercentile = $marginPct
    pePercentile = $pePct
    pe = $latestPe.value
  }
  hs300 = [pscustomobject]@{
    date = $hs300Drawdown.date
    close = $hs300Drawdown.close
    sixMonthHigh = $hs300Drawdown.high
    drawdownPct = $hs300Drawdown.drawdownPct
  }
  etf300 = [pscustomobject]@{
    date = $etf300Drawdown.date
    close = $etf300Drawdown.close
    sixMonthHigh = $etf300Drawdown.high
    drawdownPct = $etf300Drawdown.drawdownPct
    buySignal = ($hsBuyAmount -gt 0)
    sellSignal = $hsSell
    suggestedBuyAmount = $hsBuyAmount
    buyReasons = @(
      if ($hsBuyA) { "情绪温度 <= 30%" }
      if ($hsBuyB) { "沪深300近6个月回撤 >= 8%" }
      if ($peExtra -and $hsBuyAmount -gt 0) { "PE <= 13，可考虑额外加仓" }
    )
    sellReasons = @(
      if ($temp -ge 80) { "情绪温度 >= 80%" }
      if ($mediaAssessment.triggered) { "媒体叙事偏亢奋" }
      if ($socialAssessment.triggered) { "社交热度偏亢奋" }
    )
  }
  goldEtf = [pscustomobject]@{
    date = $goldDrawdown.date
    close = $goldDrawdown.close
    sixMonthHigh = $goldDrawdown.high
    drawdownPct = $goldDrawdown.drawdownPct
    buySignal = $false
    sellSignal = $false
    reasons = @(
      "黄金ETF买入提醒需要按页面中的买入后高点计算"
    )
  }
  narrative = [pscustomobject]@{
    source = $newsUrl
    recentNews = $recentNewsItems
    media = $mediaAssessment
    social = $socialAssessment
    note = "关键词评估，只用于提示复核，不等同于全网舆情模型。"
  }
}

$payload = [pscustomobject]@{
  updatedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  sources = [pscustomobject]@{
    margin = $marginUrl
    pe = $peUrl
    hs300 = $hs300Url
    etf300 = $etf300Url
    gold = $goldUrl
    news = $newsUrl
  }
  margin = $margin
  pe = $pe
  hs300 = $hs300
  etf300 = $etf300
  gold = $gold
  signals = $signals
}

$json = $payload | ConvertTo-Json -Depth 10
"window.AUTO_MARKET_DATA = $json;" | Set-Content -LiteralPath $outFile -Encoding UTF8

Write-Host ("Updated file: {0}" -f $outFile)
Write-Host ("Margin records: {0}" -f $margin.Count)
Write-Host ("PE records: {0}" -f $pe.Count)
Write-Host ("CSI 300 drawdown: {0}%" -f $hs300Drawdown.drawdownPct)
Write-Host ("300ETF buy signal: {0}; sell signal: {1}" -f ($hsBuyAmount -gt 0), $hsSell)
Write-Host "Gold ETF buy signal: calculated in page from plan anchor date"

