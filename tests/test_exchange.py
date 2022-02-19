from .conftest import approx
from brownie.test import given, strategy


@given(
        amounts=strategy('uint256[5]', min_value=10**16, max_value=10**6 * 10**18),
        ns=strategy('int256[5]', min_value=1, max_value=20),
        dns=strategy('uint256[5]', min_value=0, max_value=20),
)
def test_dxdy_limits(amm, amounts, accounts, ns, dns, collateral_token):
    admin = accounts[0]

    for user, amount, n1, dn in zip(accounts[1:6], amounts, ns, dns):
        n2 = n1 + dn
        collateral_token._mint_for_testing(user, amount)
        amm.deposit_range(user, amount, n1, n2, True, {'from': admin})
        assert collateral_token.balanceOf(user) == 0

    dx, dy = amm.get_dxdy(0, 1, 0)
    assert dx == 0 and dy == 0
    # dx, dy = amm.get_dxdy(1, 0, 0)
    # assert dx == 0 and dy == 0

    dx, dy = amm.get_dxdy(0, 1, 10**2)  # $0.0001
    assert dx == 10**2
    assert approx(dy, dx * 10**(18 - 6) / 3000, 4e-2 + 2 * min(ns) / amm.A())
