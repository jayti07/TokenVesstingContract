(define-fungible-token vesting-token)

(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-beneficiary (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-vesting-not-found (err u104))
(define-constant err-no-tokens-vested (err u105))
(define-constant err-cliff-not-reached (err u106))

;; Token metadata
(define-data-var token-name (string-ascii 32) "Vesting Token")
(define-data-var token-symbol (string-ascii 10) "VEST")
(define-data-var token-decimals uint u6)
(define-data-var total-supply uint u0)

;; Vesting schedule structure
(define-map vesting-schedules 
  principal 
  {
    total-amount: uint,
    start-time: uint,
    cliff-duration: uint,
    vesting-duration: uint,
    amount-released: uint
  })

;; Create a vesting schedule for a beneficiary
(define-public (create-vesting-schedule 
  (beneficiary principal) 
  (total-amount uint) 
  (cliff-duration uint) 
  (vesting-duration uint))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (asserts! (> total-amount u0) err-invalid-amount)
    (asserts! (>= vesting-duration cliff-duration) err-invalid-amount)
    
    ;; Mint tokens to contract for vesting
    (try! (ft-mint? vesting-token total-amount (as-contract tx-sender)))
    (var-set total-supply (+ (var-get total-supply) total-amount))
    
    ;; Create vesting schedule
    (map-set vesting-schedules beneficiary {
      total-amount: total-amount,
      start-time: stacks-block-height,
      cliff-duration: cliff-duration,
      vesting-duration: vesting-duration,
      amount-released: u0
    })
    
    (ok true)))

;; Release vested tokens to beneficiary
(define-public (release-vested-tokens)
  (let (
    (beneficiary tx-sender)
    (schedule (unwrap! (map-get? vesting-schedules beneficiary) err-vesting-not-found))
    (current-time stacks-block-height)
  )
    (let (
      (start-time (get start-time schedule))
      (cliff-duration (get cliff-duration schedule))
      (vesting-duration (get vesting-duration schedule))
      (total-amount (get total-amount schedule))
      (amount-released (get amount-released schedule))
      (cliff-end (+ start-time cliff-duration))
      (vesting-end (+ start-time vesting-duration))
    )
      ;; Check if cliff period has passed
      (asserts! (>= current-time cliff-end) err-cliff-not-reached)
      
      (let (
        (vested-amount 
          (if (>= current-time vesting-end)
            ;; If vesting period is complete, all tokens are vested
            total-amount
            ;; Otherwise, calculate linear vesting
            (/ (* total-amount (- current-time start-time)) vesting-duration)
          ))
        (releasable-amount (- vested-amount amount-released))
      )
        ;; Check if there are tokens to release
        (asserts! (> releasable-amount u0) err-no-tokens-vested)
        
        ;; Transfer vested tokens from contract to beneficiary
        (try! (as-contract (ft-transfer? vesting-token releasable-amount tx-sender beneficiary)))
        
        ;; Update released amount
        (map-set vesting-schedules beneficiary 
          (merge schedule { amount-released: vested-amount }))
        
        (ok releasable-amount)))))

;; Read-only functions for token metadata
(define-read-only (get-name)
  (ok (var-get token-name)))

(define-read-only (get-symbol)
  (ok (var-get token-symbol)))

(define-read-only (get-decimals)
  (ok (var-get token-decimals)))

(define-read-only (get-total-supply)
  (ok (var-get total-supply)))

(define-read-only (get-balance (account principal))
  (ok (ft-get-balance vesting-token account)))

;; Get vesting schedule details
(define-read-only (get-vesting-schedule (beneficiary principal))
  (ok (map-get? vesting-schedules beneficiary)))

;; Calculate releasable amount without executing release
(define-read-only (get-releasable-amount (beneficiary principal))
  (match (map-get? vesting-schedules beneficiary)
    schedule 
    (let (
      (current-time stacks-block-height)
      (start-time (get start-time schedule))
      (cliff-duration (get cliff-duration schedule))
      (vesting-duration (get vesting-duration schedule))
      (total-amount (get total-amount schedule))
      (amount-released (get amount-released schedule))
      (cliff-end (+ start-time cliff-duration))
      (vesting-end (+ start-time vesting-duration))
    )
      (if (< current-time cliff-end)
        (ok u0)  ;; Before cliff, no tokens releasable
        (let (
          (vested-amount 
            (if (>= current-time vesting-end)
              total-amount
              (/ (* total-amount (- current-time start-time)) vesting-duration)
            ))
        )
          (ok (- vested-amount amount-released)))))
    (ok u0)))  ;; No vesting schedule found