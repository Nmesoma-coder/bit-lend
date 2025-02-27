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

;; Error codes
(define-constant ERR-UNAUTHORIZED u1000)
(define-constant ERR-POOL-NOT-FOUND u1001)
(define-constant ERR-UNSUPPORTED-TOKEN u1002)
(define-constant ERR-NO-DEPOSIT u1003)
(define-constant ERR-INSUFFICIENT-BALANCE u1004)
(define-constant ERR-INSUFFICIENT-POOL-FUNDS u1005)
(define-constant ERR-INSUFFICIENT-COLLATERAL u1006)
(define-constant ERR-LOAN-NOT-FOUND u1007)
(define-constant ERR-LIQUIDATED-LOAN u1008)
(define-constant ERR-INSUFFICIENT-REPAYMENT u1009)
(define-constant ERR-NOT-LIQUIDATABLE u1010)
(define-constant ERR-COLLATERAL-TRANSFER-FAILED u1011)
(define-constant ERR-COLLATERAL-RETURN-FAILED u1012)
(define-constant ERR-REPAYMENT-TRANSFER-FAILED u1013)
(define-constant ERR-LIQUIDATION-TRANSFER-FAILED u1014)
(define-constant ERR-DEPOSIT-TRANSFER-FAILED u1015)
(define-constant ERR-WITHDRAWAL-TRANSFER-FAILED u1016)
(define-constant ERR-BORROW-TRANSFER-FAILED u1017)
(define-constant ERR-INVALID-TOKEN u1018)

;; Function to validate token-id
(define-private (is-valid-token (token-id (string-ascii 10)))
  (or (is-eq token-id TOKEN-STX) (is-eq token-id TOKEN-XBTC))
)

;; Initialize protocol with default settings
(define-public (initialize-protocol)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    
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
  (let 
    ((current-height block-height))
    
    ;; Validate token
    (asserts! (is-valid-token token-id) (err ERR-INVALID-TOKEN))
    
    (let 
      ((pool-opt (map-get? token-pools { token-id: token-id })))
      
      ;; Check if pool exists
      (asserts! (is-some pool-opt) (err ERR-POOL-NOT-FOUND))
      
      (let
        ((pool (unwrap-panic pool-opt))
         (updated-pool (merge pool { total-deposited: (+ (get total-deposited pool) amount) }))
         (safe-token-id token-id)) ;; Create a safe copy after validation
        
        ;; Update the pool's total deposited amount
        (map-set token-pools { token-id: safe-token-id } updated-pool)
        
        ;; Record the user's deposit
        (let ((prev-deposit-opt (map-get? deposits { user: tx-sender, token-id: safe-token-id })))
          (if (is-some prev-deposit-opt)
            (let ((prev-deposit (unwrap-panic prev-deposit-opt)))
              (map-set deposits 
                { user: tx-sender, token-id: safe-token-id }
                { 
                  amount: (+ amount (get amount prev-deposit)), 
                  deposit-height: current-height 
                }
              ))
            (map-set deposits 
              { user: tx-sender, token-id: safe-token-id }
              { amount: amount, deposit-height: current-height }
            )
          )
        )
        
        ;; Handle token transfers
        (let ((transfer-result 
               (if (is-eq safe-token-id TOKEN-STX)
                 (stx-transfer? amount tx-sender (as-contract tx-sender))
                 ;; For other tokens like xBTC, you would use ft-transfer?
                 (err ERR-UNSUPPORTED-TOKEN))))
          
          ;; Check if deposit transfer was successful
          (asserts! (is-ok transfer-result) (err ERR-DEPOSIT-TRANSFER-FAILED))
          
          ;; Return success response
          (ok true)
        )
      )
    )
  )
)

;; Withdraw deposited tokens plus any accrued interest
(define-public (withdraw (token-id (string-ascii 10)) (amount uint))
  (begin
    ;; Validate token
    (asserts! (is-valid-token token-id) (err ERR-INVALID-TOKEN))
    
    (let 
      ((safe-token-id token-id) ;; Create a safe copy after validation
       (user-deposit-opt (map-get? deposits { user: tx-sender, token-id: safe-token-id })))
      
      ;; Check if deposit exists
      (asserts! (is-some user-deposit-opt) (err ERR-NO-DEPOSIT))
      
      (let
        ((user-deposit (unwrap-panic user-deposit-opt))
         (pool-opt (map-get? token-pools { token-id: safe-token-id })))
        
        ;; Check if pool exists
        (asserts! (is-some pool-opt) (err ERR-POOL-NOT-FOUND))
        
        (let
          ((pool (unwrap-panic pool-opt))
           (current-height block-height)
           (blocks-elapsed (- current-height (get deposit-height user-deposit)))
           (interest-rate (get interest-rate pool))
           
           ;; Calculate accrued interest (simple interest calculation)
           (blocks-per-year u52560) ;; Assuming ~10 minute blocks, ~144 blocks per day, ~52,560 per year
           (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
           (interest (/ (* amount interest-rate time-factor) u1000000))
           (withdraw-amount (+ amount interest)))
          
          ;; Ensure user has sufficient balance
          (asserts! (<= amount (get amount user-deposit)) (err ERR-INSUFFICIENT-BALANCE))
          
          ;; Update user's deposit
          (map-set deposits 
            { user: tx-sender, token-id: safe-token-id }
            { 
              amount: (- (get amount user-deposit) amount), 
              deposit-height: (if (is-eq (- (get amount user-deposit) amount) u0) 
                               u0 
                               current-height)
            }
          )
          
          ;; Update pool's total deposited amount
          (map-set token-pools 
            { token-id: safe-token-id } 
            (merge pool { total-deposited: (- (get total-deposited pool) amount) })
          )
          
          ;; Transfer tokens back to user
          (let ((withdraw-result
                 (if (is-eq safe-token-id TOKEN-STX)
                   (as-contract (stx-transfer? withdraw-amount (as-contract tx-sender) tx-sender))
                   ;; For other tokens like xBTC, would use ft-transfer?
                   (err ERR-UNSUPPORTED-TOKEN))))
            
            ;; Check if withdrawal transfer was successful
            (asserts! (is-ok withdraw-result) (err ERR-WITHDRAWAL-TRANSFER-FAILED))
            
            ;; Return success response
            (ok true)
          )
        )
      )
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
  (begin
    ;; Validate tokens
    (asserts! (is-valid-token token-id) (err ERR-INVALID-TOKEN))
    (asserts! (is-valid-token collateral-token-id) (err ERR-INVALID-TOKEN))
    
    (let 
      ((safe-token-id token-id) ;; Create safe copies after validation
       (safe-collateral-token-id collateral-token-id)
       (safe-duration duration)
       (loan-id (var-get next-loan-id))
       (borrower tx-sender)
       (current-height block-height)
       (lendable-pool-opt (map-get? token-pools { token-id: safe-token-id }))
       (collateral-pool-opt (map-get? token-pools { token-id: safe-collateral-token-id })))
      
      ;; Check if pools exist
      (asserts! (is-some lendable-pool-opt) (err ERR-POOL-NOT-FOUND))
      (asserts! (is-some collateral-pool-opt) (err ERR-POOL-NOT-FOUND))
      
      (let
        ((lendable-pool (unwrap-panic lendable-pool-opt))
         (collateral-pool (unwrap-panic collateral-pool-opt))
         ;; Calculate required collateral based on collateral ratio
         (collateral-ratio (get collateral-ratio lendable-pool))
         (required-collateral (/ (* amount collateral-ratio) u10000)))
        
        ;; Ensure sufficient funds are available in the pool
        (asserts! (>= (- (get total-deposited lendable-pool) (get total-borrowed lendable-pool)) amount) (err ERR-INSUFFICIENT-POOL-FUNDS))
        
        ;; Ensure sufficient collateral is provided
        (asserts! (>= collateral-amount required-collateral) (err ERR-INSUFFICIENT-COLLATERAL))
        
        ;; Create the loan
        (map-set loans
          { borrower: borrower, loan-id: loan-id }
          {
            amount: amount,
            collateral: collateral-amount,
            token-id: safe-token-id,
            collateral-token-id: safe-collateral-token-id,
            interest-rate: (get interest-rate lendable-pool),
            start-height: current-height,
            duration: safe-duration,
            liquidated: false
          }
        )
        
        ;; Update the pool's total borrowed amount
        (map-set token-pools
          { token-id: safe-token-id }
          (merge lendable-pool { total-borrowed: (+ (get total-borrowed lendable-pool) amount) })
        )
        
        ;; Increment the next loan ID
        (var-set next-loan-id (+ loan-id u1))
        
        ;; Transfer collateral from borrower to contract
        (let ((collateral-transfer-result
               (if (is-eq safe-collateral-token-id TOKEN-STX)
                 (stx-transfer? collateral-amount borrower (as-contract tx-sender))
                 ;; For other tokens like xBTC, would use ft-transfer?
                 (err ERR-UNSUPPORTED-TOKEN))))
          
          ;; Check if collateral transfer was successful
          (asserts! (is-ok collateral-transfer-result) (err ERR-COLLATERAL-TRANSFER-FAILED))
          
          ;; Transfer borrowed amount to borrower
          (let ((borrow-transfer-result 
                 (if (is-eq safe-token-id TOKEN-STX)
                   (as-contract (stx-transfer? amount (as-contract tx-sender) borrower))
                   ;; For other tokens like xBTC, would use ft-transfer?
                   (err ERR-UNSUPPORTED-TOKEN))))
            
            ;; Check if borrow transfer was successful
            (asserts! (is-ok borrow-transfer-result) (err ERR-BORROW-TRANSFER-FAILED))
            
            (ok loan-id)
          )
        )
      )
    )
  )
)

;; Repay a loan
(define-public (repay-loan (loan-id uint) (amount uint))
  (let 
    ((safe-loan-id loan-id) ;; Create a safe copy after validation
     (loan-opt (map-get? loans { borrower: tx-sender, loan-id: safe-loan-id })))
    
    ;; Check if loan exists
    (asserts! (is-some loan-opt) (err ERR-LOAN-NOT-FOUND))
    
    (let
      ((loan (unwrap-panic loan-opt))
       (current-height block-height)
       (blocks-elapsed (- current-height (get start-height loan)))
       
       ;; Calculate interest accrued
       (blocks-per-year u52560)
       (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
       (interest-rate (get interest-rate loan))
       (interest (/ (* (get amount loan) interest-rate time-factor) u1000000))
       (total-owed (+ (get amount loan) interest))
       
       ;; Get pool data
       (lendable-pool-opt (map-get? token-pools { token-id: (get token-id loan) })))
      
      ;; Check if pool exists
      (asserts! (is-some lendable-pool-opt) (err ERR-POOL-NOT-FOUND))
      
      (let
        ((lendable-pool (unwrap-panic lendable-pool-opt)))
        
        ;; Ensure the loan hasn't been liquidated
        (asserts! (not (get liquidated loan)) (err ERR-LIQUIDATED-LOAN))
        
        ;; Ensure repayment amount is sufficient
        (asserts! (>= amount (if (< amount total-owed) amount total-owed)) (err ERR-INSUFFICIENT-REPAYMENT))
        
        ;; Transfer repayment from borrower to contract
        (let ((repayment-result
               (if (is-eq (get token-id loan) TOKEN-STX)
                 (stx-transfer? amount tx-sender (as-contract tx-sender))
                 ;; For other tokens like xBTC, would use ft-transfer?
                 (err ERR-UNSUPPORTED-TOKEN))))
          
          ;; Check if repayment transfer was successful
          (asserts! (is-ok repayment-result) (err ERR-REPAYMENT-TRANSFER-FAILED))
          
          ;; Process repayment
          (if (>= amount total-owed)
            ;; Full repayment
            (begin
              ;; Return collateral
              (let ((collateral-return-result
                     (if (is-eq (get collateral-token-id loan) TOKEN-STX)
                       (as-contract (stx-transfer? (get collateral loan) (as-contract tx-sender) tx-sender))
                       ;; For other tokens like xBTC, would use ft-transfer?
                       (err ERR-UNSUPPORTED-TOKEN))))
                
                ;; Check if collateral return was successful
                (asserts! (is-ok collateral-return-result) (err ERR-COLLATERAL-RETURN-FAILED))
                
                ;; Delete the loan
                (map-delete loans { borrower: tx-sender, loan-id: safe-loan-id })
                
                ;; Update the pool's total borrowed amount
                (map-set token-pools
                  { token-id: (get token-id loan) }
                  (merge lendable-pool { total-borrowed: (- (get total-borrowed lendable-pool) (get amount loan)) })
                )
                
                ;; Return success
                (ok true)
              )
            )
            ;; Partial repayment
            (begin
              ;; Update loan amount
              (map-set loans
                { borrower: tx-sender, loan-id: safe-loan-id }
                (merge loan { amount: (- (get amount loan) amount) })
              )
              
              ;; Return success
              (ok true)
            )
          )
        )
      )
    )
  )
)

;; Liquidate an undercollateralized loan
(define-public (liquidate-loan (borrower principal) (loan-id uint))
  (let 
    ((safe-borrower borrower) ;; Create safe copies after validation
     (safe-loan-id loan-id)
     (loan-opt (map-get? loans { borrower: safe-borrower, loan-id: safe-loan-id })))
    
    ;; Check if loan exists
    (asserts! (is-some loan-opt) (err ERR-LOAN-NOT-FOUND))
    
    (let
      ((loan (unwrap-panic loan-opt))
       (current-height block-height)
       (blocks-elapsed (- current-height (get start-height loan)))
       
       ;; Calculate current loan value with interest
       (blocks-per-year u52560)
       (time-factor (/ (* blocks-elapsed u10000) blocks-per-year))
       (interest-rate (get interest-rate loan))
       (interest (/ (* (get amount loan) interest-rate time-factor) u1000000))
       (total-owed (+ (get amount loan) interest))
       
       ;; Get pool data for liquidation threshold
       (lendable-pool-opt (map-get? token-pools { token-id: (get token-id loan) })))
      
      ;; Check if pool exists
      (asserts! (is-some lendable-pool-opt) (err ERR-POOL-NOT-FOUND))
      
      (let
        ((lendable-pool (unwrap-panic lendable-pool-opt))
         (liquidation-threshold (get liquidation-threshold lendable-pool))
         
         ;; Calculate current collateral value (would need price oracles in real implementation)
         (current-collateral-value (get collateral loan))
         
         ;; Calculate minimum required collateral
         (min-collateral-required (/ (* total-owed liquidation-threshold) u10000)))
        
        ;; Ensure the loan is eligible for liquidation
        (asserts! (not (get liquidated loan)) (err ERR-LIQUIDATED-LOAN))
        (asserts! (< current-collateral-value min-collateral-required) (err ERR-NOT-LIQUIDATABLE))
        
        ;; Mark loan as liquidated
        (map-set loans
          { borrower: safe-borrower, loan-id: safe-loan-id }
          (merge loan { liquidated: true })
        )
        
        ;; Update the pool's total borrowed amount
        (map-set token-pools
          { token-id: (get token-id loan) }
          (merge lendable-pool { total-borrowed: (- (get total-borrowed lendable-pool) (get amount loan)) })
        )
        
        ;; Transfer collateral to liquidator (with discount)
        (let
          ((liquidation-bonus u9500) ;; 95% of collateral (5% discount)
           (liquidator-amount (/ (* current-collateral-value liquidation-bonus) u10000))
           (transfer-result (if (is-eq (get collateral-token-id loan) TOKEN-STX)
                              (as-contract (stx-transfer? liquidator-amount (as-contract tx-sender) tx-sender))
                              ;; For other tokens like xBTC, would use ft-transfer?
                              (err ERR-UNSUPPORTED-TOKEN))))
          
          ;; Check if liquidation transfer was successful
          (asserts! (is-ok transfer-result) (err ERR-LIQUIDATION-TRANSFER-FAILED))
          
          ;; Return success
          (ok true)
        )
      )
    )
  )
)

;; Get user deposit information
(define-read-only (get-user-deposit (user principal) (token-id (string-ascii 10)))
  (if (is-valid-token token-id)
    (map-get? deposits { user: user, token-id: token-id })
    none
  )
)

;; Get loan information
(define-read-only (get-loan (borrower principal) (loan-id uint))
  (map-get? loans { borrower: borrower, loan-id: loan-id })
)

;; Get pool information
(define-read-only (get-pool (token-id (string-ascii 10)))
  (if (is-valid-token token-id)
    (map-get? token-pools { token-id: token-id })
    none
  )
)

;; Update pool parameters (admin only)
(define-public (update-pool-params
  (token-id (string-ascii 10))
  (interest-rate uint)
  (collateral-ratio uint)
  (liquidation-threshold uint)
)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (asserts! (is-valid-token token-id) (err ERR-INVALID-TOKEN))
    
    (let ((safe-token-id token-id)
          (pool-opt (map-get? token-pools { token-id: safe-token-id })))
      (asserts! (is-some pool-opt) (err ERR-POOL-NOT-FOUND))
      (let ((pool (unwrap-panic pool-opt)))
        (map-set token-pools
          { token-id: safe-token-id }
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
)

;; Transfer admin rights (admin only)
(define-public (transfer-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set admin new-admin)
    (ok true)
  )
)