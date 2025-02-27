;; BitLend - A DeFi Lending Protocol on Stacks
;; This contract enables users to deposit STX and Bitcoin (via wrapped BTC) to earn interest
;; and allows other users to borrow against these deposits by providing collateral.

(define-data-var admin principal tx-sender)
(define-map deposits
  { user: principal, token-id: (string-ascii 10) }
  { amount: uint, deposit-height: uint }
)
(define-map loans
  { borrower: principal, loan-id: uint }
  { 
    amount: uint, 
    collateral: uint, 
    token-id: (string-ascii 10),
    collateral-token-id: (string-ascii 10),
    interest-rate: uint,
    start-height: uint,
    duration: uint,
    liquidated: bool
  }
)
(define-map token-pools
  { token-id: (string-ascii 10) }
  { 
    total-deposited: uint, 
    total-borrowed: uint,
    interest-rate: uint,
    collateral-ratio: uint,
    liquidation-threshold: uint
  }
)

(define-data-var next-loan-id uint u0)

;; Supported token constants
(define-constant TOKEN-STX "STX")
(define-constant TOKEN-XBTC "xBTC")

;; Initialize protocol with default settings
(define-public (initialize-protocol)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err u1000))
    
    ;; Initialize STX pool
    (map-set token-pools 
      { token-id: TOKEN-STX }
      { 
        total-deposited: u0, 
        total-borrowed: u0,
        interest-rate: u500,         ;; 5.00% APR (scaled by 100)
        collateral-ratio: u15000,    ;; 150% (scaled by 100)
        liquidation-threshold: u12500 ;; 125% (scaled by 100)
      }
    )
    
    ;; Initialize xBTC pool
    (map-set token-pools 
      { token-id: TOKEN-XBTC }
      { 
        total-deposited: u0, 
        total-borrowed: u0,
        interest-rate: u300,         ;; 3.00% APR (scaled by 100)
        collateral-ratio: u13000,    ;; 130% (scaled by 100)
        liquidation-threshold: u11000 ;; 110% (scaled by 100)
      }
    )
    
    (ok true)
  )
)

;; Deposit tokens to earn interest
(define-public (deposit (token-id (string-ascii 10)) (amount uint))
  (let (
    (current-height block-height)
    (pool (unwrap! (map-get? token-pools { token-id: token-id }) (err u1001)))
    (updated-pool (merge pool { total-deposited: (+ (get total-deposited pool) amount) }))
  )
    ;; Update the pool's total deposited amount
    (map-set token-pools { token-id: token-id } updated-pool)
    
    ;; Record the user's deposit
    (match (map-get? deposits { user: tx-sender, token-id: token-id })
      prev-deposit
      (map-set deposits 
        { user: tx-sender, token-id: token-id }
        { 
          amount: (+ amount (get amount prev-deposit)), 
          deposit-height: current-height 
        }
      )
      (map-set deposits 
        { user: tx-sender, token-id: token-id }
        { amount: amount, deposit-height: current-height }
      )
    )
    
    ;; Handle token transfers (in real implementation, this would include FT transfers)
    (if (is-eq token-id TOKEN-STX)
      (stx-transfer? amount tx-sender (as-contract tx-sender))
      ;; For other tokens like xBTC, you would use ft-transfer?
      (err u1002)
    )
  )
)

;; Withdraw deposited tokens plus any accrued interest
(define-public (withdraw (token-id (string-ascii 10)) (amount uint))
  (let (
    (user-deposit (unwrap! (map-get? deposits { user: tx-sender, token-id: token-id }) (err u1003)))
    (pool (unwrap! (map-get? token-pools { token-id: token-id }) (err u1001)))
    (current-height block-height)
    (blocks-elapsed (- current-height (get deposit-height user-deposit)))
    (interest-rate (get interest-rate pool))
    
    ;; Calculate accrued interest (simple interest calculation)
    ;; Formula: interest = principal * rate * time / 10000
    ;; Where rate is annual percentage scaled by 100, and time is in blocks converted to years
    (blocks-per-year u52560) ;; Assuming ~10 minute blocks, ~144 blocks per day, ~52,560 per year
    (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
    (interest (/ (* amount interest-rate time-factor) u1000000))
    (withdraw-amount (+ amount interest))
  )
    ;; Ensure user has sufficient balance
    (asserts! (<= amount (get amount user-deposit)) (err u1004))
    
    ;; Update user's deposit
    (map-set deposits 
      { user: tx-sender, token-id: token-id }
      { 
        amount: (- (get amount user-deposit) amount), 
        deposit-height: (if (is-eq (- (get amount user-deposit) amount) u0) 
                         u0 
                         current-height)
      }
    )
    
    ;; Update pool's total deposited amount
    (map-set token-pools 
      { token-id: token-id } 
      (merge pool { total-deposited: (- (get total-deposited pool) amount) })
    )
    
    ;; Transfer tokens back to user (in real implementation, would include FT transfers)
    (if (is-eq token-id TOKEN-STX)
      (as-contract (stx-transfer? withdraw-amount (as-contract tx-sender) tx-sender))
      ;; For other tokens like xBTC, would use ft-transfer?
      (err u1002)
    )
  )
)

;; Borrow against collateral
(define-public (borrow
  (token-id (string-ascii 10))
  (amount uint)
  (collateral-token-id (string-ascii 10))
  (collateral-amount uint)
  (duration uint)
)
  (let (
    (loan-id (var-get next-loan-id))
    (borrower tx-sender)
    (current-height block-height)
    (lendable-pool (unwrap! (map-get? token-pools { token-id: token-id }) (err u1001)))
    (collateral-pool (unwrap! (map-get? token-pools { token-id: collateral-token-id }) (err u1001)))
    
    ;; Calculate required collateral based on collateral ratio
    (collateral-ratio (get collateral-ratio lendable-pool))
    (required-collateral (/ (* amount collateral-ratio) u10000))
  )
    ;; Ensure sufficient funds are available in the pool
    (asserts! (>= (- (get total-deposited lendable-pool) (get total-borrowed lendable-pool)) amount) (err u1005))
    
    ;; Ensure sufficient collateral is provided
    (asserts! (>= collateral-amount required-collateral) (err u1006))
    
    ;; Create the loan
    (map-set loans
      { borrower: borrower, loan-id: loan-id }
      {
        amount: amount,
        collateral: collateral-amount,
        token-id: token-id,
        collateral-token-id: collateral-token-id,
        interest-rate: (get interest-rate lendable-pool),
        start-height: current-height,
        duration: duration,
        liquidated: false
      }
    )
    
    ;; Update the pool's total borrowed amount
    (map-set token-pools
      { token-id: token-id }
      (merge lendable-pool { total-borrowed: (+ (get total-borrowed lendable-pool) amount) })
    )
    
    ;; Increment the next loan ID
    (var-set next-loan-id (+ loan-id u1))
    
    ;; Transfer collateral from borrower to contract
    (if (is-eq collateral-token-id TOKEN-STX)
      (stx-transfer? collateral-amount borrower (as-contract tx-sender))
      ;; For other tokens like xBTC, would use ft-transfer?
      (err u1002)
    )
    
    ;; Transfer borrowed amount to borrower
    (if (is-eq token-id TOKEN-STX)
      (as-contract (stx-transfer? amount (as-contract tx-sender) borrower))
      ;; For other tokens like xBTC, would use ft-transfer?
      (err u1002)
    )
    
    (ok loan-id)
  )
)

;; Repay a loan
(define-public (repay-loan (loan-id uint) (amount uint))
  (let (
    (loan (unwrap! (map-get? loans { borrower: tx-sender, loan-id: loan-id }) (err u1007)))
    (current-height block-height)
    (blocks-elapsed (- current-height (get start-height loan)))
    
    ;; Calculate interest accrued
    (blocks-per-year u52560)
    (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
    (interest-rate (get interest-rate loan))
    (interest (/ (* (get amount loan) interest-rate time-factor) u1000000))
    (total-owed (+ (get amount loan) interest))
    
    ;; Update pool data
    (lendable-pool (unwrap! (map-get? token-pools { token-id: (get token-id loan) }) (err u1001)))
  )
    ;; Ensure the loan hasn't been liquidated
    (asserts! (not (get liquidated loan)) (err u1008))
    
    ;; Ensure repayment amount is sufficient
    (asserts! (>= amount (if (< amount total-owed) amount total-owed)) (err u1009))
    
    ;; Transfer repayment from borrower to contract
    (if (is-eq (get token-id loan) TOKEN-STX)
      (stx-transfer? amount tx-sender (as-contract tx-sender))
      ;; For other tokens like xBTC, would use ft-transfer?
      (err u1002)
    )
    
    ;; If full repayment, return collateral
    (if (>= amount total-owed)
      (begin
        ;; Return collateral
        (if (is-eq (get collateral-token-id loan) TOKEN-STX)
          (as-contract (stx-transfer? (get collateral loan) (as-contract tx-sender) tx-sender))
          ;; For other tokens like xBTC, would use ft-transfer?
          (err u1002)
        )
        
        ;; Delete the loan
        (map-delete loans { borrower: tx-sender, loan-id: loan-id })
        
        ;; Update the pool's total borrowed amount
        (map-set token-pools
          { token-id: (get token-id loan) }
          (merge lendable-pool { total-borrowed: (- (get total-borrowed lendable-pool) (get amount loan)) })
        )
      )
      ;; Partial repayment
      (map-set loans
        { borrower: tx-sender, loan-id: loan-id }
        (merge loan { amount: (- (get amount loan) amount) })
      )
    )
    
    (ok true)
  )
)

;; Liquidate an undercollateralized loan
(define-public (liquidate-loan (borrower principal) (loan-id uint))
  (let (
    (loan (unwrap! (map-get? loans { borrower: borrower, loan-id: loan-id }) (err u1007)))
    (current-height block-height)
    (blocks-elapsed (- current-height (get start-height loan)))
    
    ;; Calculate current loan value with interest
    (blocks-per-year u52560)
    (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
    (interest-rate (get interest-rate loan))
    (interest (/ (* (get amount loan) interest-rate time-factor) u1000000))
    (total-owed (+ (get amount loan) interest))
    
    ;; Get pool data for liquidation threshold
    (lendable-pool (unwrap! (map-get? token-pools { token-id: (get token-id loan) }) (err u1001)))
    (liquidation-threshold (get liquidation-threshold lendable-pool))
    
    ;; Calculate current collateral value (would need price oracles in real implementation)
    (current-collateral-value (get collateral loan))
    
    ;; Calculate minimum required collateral
    (min-collateral-required (/ (* total-owed liquidation-threshold) u10000))
  )
    ;; Ensure the loan is eligible for liquidation
    (asserts! (not (get liquidated loan)) (err u1008))
    (asserts! (< current-collateral-value min-collateral-required) (err u1010))
    
    ;; Mark loan as liquidated
    (map-set loans
      { borrower: borrower, loan-id: loan-id }
      (merge loan { liquidated: true })
    )
    
    ;; Update the pool's total borrowed amount
    (map-set token-pools
      { token-id: (get token-id loan) }
      (merge lendable-pool { total-borrowed: (- (get total-borrowed lendable-pool) (get amount loan)) })
    )
    
    ;; Transfer collateral to liquidator (with discount)
    (let (
      (liquidation-bonus u9500) ;; 95% of collateral (5% discount)
      (liquidator-amount (/ (* current-collateral-value liquidation-bonus) u10000))
    )
      (if (is-eq (get collateral-token-id loan) TOKEN-STX)
        (as-contract (stx-transfer? liquidator-amount (as-contract tx-sender) tx-sender))
        ;; For other tokens like xBTC, would use ft-transfer?
        (err u1002)
      )
    )
    
    (ok true)
  )
)

;; Get user deposit information
(define-read-only (get-user-deposit (user principal) (token-id (string-ascii 10)))
  (map-get? deposits { user: user, token-id: token-id })
)

;; Get loan information
(define-read-only (get-loan (borrower principal) (loan-id uint))
  (map-get? loans { borrower: borrower, loan-id: loan-id })
)

;; Get pool information
(define-read-only (get-pool (token-id (string-ascii 10)))
  (map-get? token-pools { token-id: token-id })
)

;; Update pool parameters (admin only)
(define-public (update-pool-params
  (token-id (string-ascii 10))
  (interest-rate uint)
  (collateral-ratio uint)
  (liquidation-threshold uint)
)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err u1000))
    (let (
      (pool (unwrap! (map-get? token-pools { token-id: token-id }) (err u1001)))
    )
      (map-set token-pools
        { token-id: token-id }
        (merge pool {
          interest-rate: interest-rate,
          collateral-ratio: collateral-ratio,
          liquidation-threshold: liquidation-threshold
        })
      )
      (ok true)
    )
  )
)

;; Transfer admin rights (admin only)
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err u1000))
    (var-set admin new-admin)
    (ok true)
  )
)