# @version 0.3.7
"""
@title Peg Keeper
@license MIT
@author Curve.Fi
@notice Peg Keeper for pool with equal decimals of coins
"""

interface StableAggregator:
    def price() -> uint256: view

interface CurvePool:
    def balances(i_coin: uint256) -> uint256: view
    def coins(i: uint256) -> address: view
    def add_liquidity(_amounts: uint256[2], _min_mint_amount: uint256) -> uint256: nonpayable
    def remove_liquidity_imbalance(_amounts: uint256[2], _max_burn_amount: uint256) -> uint256: nonpayable
    def get_virtual_price() -> uint256: view
    def balanceOf(arg0: address) -> uint256: view
    def transfer(_to : address, _value : uint256) -> bool: nonpayable
    def get_p() -> uint256: view

interface ERC20:
    def approve(_spender: address, _amount: uint256): nonpayable


event Provide:
    amount: uint256

event Withdraw:
    amount: uint256

event Profit:
    lp_amount: uint256

event CommitNewReceiver:
    receiver: address

event ApplyNewReceiver:
    receiver: address

event CommitNewAdmin:
    admin: address

event ApplyNewAdmin:
    admin: address

event SetNewCallerShare:
    caller_share: uint256


# Time between providing/withdrawing coins
ACTION_DELAY: constant(uint256) = 15 * 60
ADMIN_ACTIONS_DELAY: constant(uint256) = 3 * 86400

PRECISION: constant(uint256) = 10 ** 18
# Calculation error for profit
PROFIT_THRESHOLD: constant(uint256) = 10 ** 18

POOL: immutable(CurvePool)
I: immutable(uint256)  # index of pegged in pool
PEGGED: immutable(address)
IS_INVERSE: immutable(bool)

AGGREGATOR: immutable(StableAggregator)

last_change: public(uint256)
debt: public(uint256)

SHARE_PRECISION: constant(uint256) = 10 ** 5
caller_share: public(uint256)

admin: public(address)
future_admin: public(address)

# Receiver of profit
receiver: public(address)
future_receiver: public(address)

new_admin_deadline: public(uint256)
new_receiver_deadline: public(uint256)

FACTORY: immutable(address)


@external
def __init__(_pool: CurvePool, _index: uint256, _receiver: address, _caller_share: uint256, _factory: address, _aggregator: StableAggregator):
    """
    @notice Contract constructor
    @param _pool Contract pool address
    @param _index Index of the pegged
    @param _receiver Receiver of the profit
    @param _caller_share Caller's share of profit
    @param _factory Factory which should be able to take coins away
    @param _aggregator Price aggregator which shows the price of pegged in real "dollars"
    """
    assert _index < 2
    POOL = _pool
    I = _index
    pegged: address = _pool.coins(_index)
    PEGGED = pegged
    ERC20(pegged).approve(_pool.address, max_value(uint256))
    ERC20(pegged).approve(_factory, max_value(uint256))

    self.admin = msg.sender
    self.receiver = _receiver
    log ApplyNewAdmin(msg.sender)
    log ApplyNewReceiver(_receiver)

    self.caller_share = _caller_share
    log SetNewCallerShare(_caller_share)

    FACTORY = _factory
    AGGREGATOR = _aggregator
    IS_INVERSE = (_index == 0)


@pure
@external
def factory() -> address:
    return FACTORY


@pure
@external
def pegged() -> address:
    return PEGGED


@pure
@external
def pool() -> CurvePool:
    return POOL


@pure
@external
def aggregator() -> StableAggregator:
    return AGGREGATOR


@internal
def _provide(_amount: uint256):
    # We already have all reserves here
    # ERC20(PEGGED).mint(self, _amount)

    amounts: uint256[2] = empty(uint256[2])
    amounts[I] = _amount
    POOL.add_liquidity(amounts, 0)

    self.last_change = block.timestamp
    self.debt += _amount
    log Provide(_amount)


@internal
def _withdraw(_amount: uint256):
    debt: uint256 = self.debt
    amount: uint256 = _amount
    if amount > debt:
        amount = debt

    amounts: uint256[2] = empty(uint256[2])
    amounts[I] = amount
    POOL.remove_liquidity_imbalance(amounts, max_value(uint256))

    self.last_change = block.timestamp
    self.debt -= amount

    log Withdraw(amount)


@internal
@view
def _calc_profit() -> uint256:
    lp_balance: uint256 = POOL.balanceOf(self)

    virtual_price: uint256 = POOL.get_virtual_price()
    lp_debt: uint256 = self.debt * PRECISION / virtual_price

    if lp_balance <= lp_debt + PROFIT_THRESHOLD:
        return 0
    else:
        return lp_balance - lp_debt - PROFIT_THRESHOLD


@internal
@view
def _pool_price() -> uint256:
    p: uint256 = POOL.get_p()
    if IS_INVERSE:
        return 10**36 / p
    else:
        return p


@external
@view
def calc_profit() -> uint256:
    """
    @notice Calculate generated profit in LP tokens
    @return Amount of generated profit
    """
    return self._calc_profit()


@external
@nonpayable
def update(_beneficiary: address = msg.sender) -> uint256:
    """
    @notice Provide or withdraw coins from the pool to stabilize it
    @param _beneficiary Beneficiary address
    @return Amount of profit received by beneficiary
    """
    if self.last_change + ACTION_DELAY > block.timestamp:
        return 0

    balance_pegged: uint256 = POOL.balances(I)
    balance_peg: uint256 = POOL.balances(1 - I)

    initial_profit: uint256 = self._calc_profit()

    p_agg: uint256 = AGGREGATOR.price()  # Current USD per stablecoin
    p0: uint256 = self._pool_price()  # USDT per stablecoin

    if balance_peg > balance_pegged:
        self._provide((balance_peg - balance_pegged) / 5)
        # self._pool_price() >= p0 * 10**18 / p_agg
        assert self._pool_price() * p_agg >= p0 * 10**18

    else:
        self._withdraw((balance_pegged - balance_peg) / 5)
        # self._pool_price() <= p0 * 10**18 / p_agg
        assert self._pool_price() * p_agg <= p0 * 10**18

    # Send generated profit
    new_profit: uint256 = self._calc_profit()
    assert new_profit >= initial_profit  # dev: peg was unprofitable
    lp_amount: uint256 = new_profit - initial_profit
    caller_profit: uint256 = lp_amount * self.caller_share / SHARE_PRECISION
    POOL.transfer(_beneficiary, caller_profit)

    return caller_profit


@external
@nonpayable
def set_new_caller_share(_new_caller_share: uint256):
    """
    @notice Set new update caller's part
    @param _new_caller_share Part with SHARE_PRECISION
    """
    assert msg.sender == self.admin  # dev: only admin
    assert _new_caller_share <= SHARE_PRECISION  # dev: bad part value

    self.caller_share = _new_caller_share

    log SetNewCallerShare(_new_caller_share)


@external
@nonpayable
def withdraw_profit() -> uint256:
    """
    @notice Withdraw profit generated by Peg Keeper
    @return Amount of LP Token received
    """
    lp_amount: uint256 = self._calc_profit()
    POOL.transfer(self.receiver, lp_amount)

    log Profit(lp_amount)

    return lp_amount


@external
@nonpayable
def commit_new_admin(_new_admin: address):
    """
    @notice Commit new admin of the Peg Keeper
    @param _new_admin Address of the new admin
    """
    assert msg.sender == self.admin  # dev: only admin
    assert self.new_admin_deadline == 0 # dev: active action

    deadline: uint256 = block.timestamp + ADMIN_ACTIONS_DELAY
    self.new_admin_deadline = deadline
    self.future_admin = _new_admin

    log CommitNewAdmin(_new_admin)


@external
@nonpayable
def apply_new_admin():
    """
    @notice Apply new admin of the Peg Keeper
    @dev Should be executed from new admin
    """
    new_admin: address = self.future_admin
    assert msg.sender == new_admin  # dev: only new admin
    assert block.timestamp >= self.new_admin_deadline  # dev: insufficient time
    assert self.new_admin_deadline != 0  # dev: no active action

    self.admin = new_admin
    self.new_admin_deadline = 0

    log ApplyNewAdmin(new_admin)


@external
@nonpayable
def commit_new_receiver(_new_receiver: address):
    """
    @notice Commit new receiver of profit
    @param _new_receiver Address of the new receiver
    """
    assert msg.sender == self.admin  # dev: only admin
    assert self.new_receiver_deadline == 0 # dev: active action

    deadline: uint256 = block.timestamp + ADMIN_ACTIONS_DELAY
    self.new_receiver_deadline = deadline
    self.future_receiver = _new_receiver

    log CommitNewReceiver(_new_receiver)


@external
@nonpayable
def apply_new_receiver():
    """
    @notice Apply new receiver of profit
    """
    assert block.timestamp >= self.new_receiver_deadline  # dev: insufficient time
    assert self.new_receiver_deadline != 0  # dev: no active action

    new_receiver: address = self.future_receiver
    self.receiver = new_receiver
    self.new_receiver_deadline = 0

    log ApplyNewReceiver(new_receiver)


@external
@nonpayable
def revert_new_options():
    """
    @notice Revert new admin of the Peg Keeper or new receiver
    @dev Should be executed from admin
    """
    assert msg.sender == self.admin  # dev: only admin

    self.new_admin_deadline = 0
    self.new_receiver_deadline = 0

    log ApplyNewAdmin(self.admin)
    log ApplyNewReceiver(self.receiver)
