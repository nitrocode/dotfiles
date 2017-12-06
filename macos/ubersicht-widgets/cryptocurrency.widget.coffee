
# From CryptoCurrency. Add or remove. 40+ supportet coins, check here: https://www.cryptocompare.com/api/data/coinlist/
ccur = ['BTC', 'ETH', 'XMR', 'DASH',]

#To Currency
currency = 'USD'

# Made possibly with Cryptocompares API (www.cryptocompare.com)

req = ccur.join(", ")
command: "curl -s 'https://min-api.cryptocompare.com/data/pricemultifull?fsyms=#{ccur}&tsyms=#{currency}'"

refreshFrequency: 100000

style: """
  top: 20px
  right: 100px
  color: #fff
  font-family: Helvetica Neue

  table
    border-collapse: collapsec
    table-layout: fixed
    -webkit-font-smoothing: antialiased
    -moz-osx-font-smoothing: grayscale

    &:after
      position: absolute
      left: 0
      top: -14px
      font-size: 12px

  td
    font-size: 30px
    font-weight: 200
    width: 200px
    max-width: 400px
    overflow: hidden

  .wrapper
    padding: 5px 5px 5px 5px
    position: relative

  .label
    font-weight: normal
    font-size: 16 px

  .cur
    font-size: 15px
    font-weight: normal
    max-width: 100%

  .pos
    color: #66ff66

  .neg
    color: #ff6666
"""


render: -> """
  <table><tr><td>Network Error</td></tr></table>
"""


update: (output, domEl) ->
  res = JSON.parse(output)
  data = Object.keys(res.DISPLAY).map((k) -> res.DISPLAY[k])
  console.log data
  table  = $(domEl).find('table')
  table.html ""

  renderCurrency = (label, price, change, state) ->
    """
    <td>
      <div class="wrapper">
        <span class=label>#{label}</span> <br>
        #{price}
        <div class="cur #{state}">#{change}%</div>
      </div>
    </td>
    """

  for value, i in data
    label = ccur[i]
    price = data[i][currency]['PRICE']
    change = data[i][currency]['CHANGEPCT24HOUR']
    state = if (change.charAt(0) == '+') then 'pos' else 'neg'
    if i % 2 == 0
      table.append "<tr/>"
    table.find("tr:last").append renderCurrency(label, price, change, state)
