;; title: Dynamic Payment Channel Network
;; summary: A smart contract for managing dynamic payment channels on the Stacks blockchain.
;; description: This contract allows participants to create, fund, and manage payment channels. It supports functionalities such as making payments, closing channels, and resolving disputes. The contract ensures secure and efficient transactions between participants using Clarity smart contracts.

;; Constants
(define-constant ERR-UNAUTHORIZED (err u1))
(define-constant ERR-CHANNEL-EXISTS (err u2))
(define-constant ERR-CHANNEL-NOT-FOUND (err u3))
(define-constant ERR-INSUFFICIENT-BALANCE (err u4))
(define-constant ERR-INVALID-SIGNATURE (err u5))
(define-constant ERR-CHANNEL-CLOSED (err u6))
(define-constant ERR-INVALID-STATE (err u7))

;; Data Maps
(define-map channels
  { channel-id: (buff 32) }
  {
    participant1: principal,
    participant2: principal,
    balance1: uint,
    balance2: uint,
    nonce: uint,
    state: (string-ascii 20)
  }
)

(define-map participant-channels
  { participant: principal }
  { channel-ids: (list 100 (buff 32)) }
)

;; Helper Functions
(define-private (uint-to-buff (value uint))
  (unwrap-panic (as-max-len? (concat 
    (unwrap-panic (as-max-len? (concat 
      (unwrap-panic (as-max-len? (concat 
        (unwrap-panic (as-max-len? (concat 
          0x00 
          (if (> value u16777215) (buff-to-u8 (/ value u16777216)) 0x00)
        ) u1))
        (if (> value u65535) (buff-to-u8 (mod (/ value u65536) u256)) 0x00)
      ) u2))
      (if (> value u255) (buff-to-u8 (mod (/ value u256) u256)) 0x00)
    ) u3))
    (buff-to-u8 (mod value u256))
  ) u4))
)

(define-private (buff-to-u8 (byte uint))
  (unwrap-panic (element-at 
    0x000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
    byte
  ))
)

;; Private Functions
(define-private (validate-signature (channel-id (buff 32)) (amount uint) (nonce uint) (signature (buff 65)))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
    (participant1 (get participant1 channel))
    (participant2 (get participant2 channel))
    (message (concat (concat channel-id (uint-to-buff amount)) (uint-to-buff nonce)))
  )
    (asserts! (or
      (is-eq (secp256k1-recover? message signature) (ok participant1))
      (is-eq (secp256k1-recover? message signature) (ok participant2))
    ) ERR-INVALID-SIGNATURE)
  )
)

(define-private (update-participant-channels (participant principal) (channel-id (buff 32)))
  (let (
    (current-channels (default-to { channel-ids: (list) } (map-get? participant-channels { participant: participant })))
  )
    (map-set participant-channels
      { participant: participant }
      { channel-ids: (unwrap! (as-max-len? (append (get channel-ids current-channels) channel-id) u100) ERR-INVALID-STATE) }
    )
  )
)

;; Public Functions
(define-public (create-channel (participant2 principal) (initial-balance1 uint) (initial-balance2 uint))
  (let (
    (channel-id (sha256 (concat (concat (as-max-len? (concat tx-sender participant2) u60) (uint-to-buff block-height)) (uint-to-buff initial-balance1))))
  )
    (asserts! (is-none (map-get? channels { channel-id: channel-id })) ERR-CHANNEL-EXISTS)
    (asserts! (>= (stx-get-balance tx-sender) initial-balance1) ERR-INSUFFICIENT-BALANCE)
    (asserts! (>= (stx-get-balance participant2) initial-balance2) ERR-INSUFFICIENT-BALANCE)
    
    (try! (stx-transfer? initial-balance1 tx-sender (as-contract tx-sender)))
    (try! (stx-transfer? initial-balance2 participant2 (as-contract tx-sender)))
    
    (map-set channels
      { channel-id: channel-id }
      {
        participant1: tx-sender,
        participant2: participant2,
        balance1: initial-balance1,
        balance2: initial-balance2,
        nonce: u0,
        state: "OPEN"
      }
    )
    
    (update-participant-channels tx-sender channel-id)
    (update-participant-channels participant2 channel-id)
    
    (ok channel-id)
  )
)

(define-public (fund-channel (channel-id (buff 32)) (amount uint))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
  )
    (asserts! (or
      (is-eq tx-sender (get participant1 channel))
      (is-eq tx-sender (get participant2 channel))
    ) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get state channel) "OPEN") ERR-CHANNEL-CLOSED)
    
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    (if (is-eq tx-sender (get participant1 channel))
      (map-set channels
        { channel-id: channel-id }
        (merge channel { balance1: (+ (get balance1 channel) amount) })
      )
      (map-set channels
        { channel-id: channel-id }
        (merge channel { balance2: (+ (get balance2 channel) amount) })
      )
    )
    
    (ok true)
  )
)

(define-public (make-payment (channel-id (buff 32)) (amount uint) (nonce uint) (signature (buff 65)))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
  )
    (asserts! (is-eq (get state channel) "OPEN") ERR-CHANNEL-CLOSED)
    (asserts! (> nonce (get nonce channel)) ERR-INVALID-STATE)
    (try! (validate-signature channel-id amount nonce signature))
    
    (if (is-eq tx-sender (get participant1 channel))
      (asserts! (<= amount (get balance1 channel)) ERR-INSUFFICIENT-BALANCE)
      (asserts! (<= amount (get balance2 channel)) ERR-INSUFFICIENT-BALANCE)
    )
    
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        balance1: (if (is-eq tx-sender (get participant1 channel))
          (- (get balance1 channel) amount)
          (+ (get balance1 channel) amount)
        ),
        balance2: (if (is-eq tx-sender (get participant2 channel))
          (- (get balance2 channel) amount)
          (+ (get balance2 channel) amount)
        ),
        nonce: nonce
      })
    )
    
    (ok true)
  )
)

(define-public (close-channel (channel-id (buff 32)))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
  )
    (asserts! (or
      (is-eq tx-sender (get participant1 channel))
      (is-eq tx-sender (get participant2 channel))
    ) ERR-UNAUTHORIZED)
    (asserts! (is-eq (get state channel) "OPEN") ERR-CHANNEL-CLOSED)
    
    (try! (as-contract (stx-transfer? (get balance1 channel) tx-sender (get participant1 channel))))
    (try! (as-contract (stx-transfer? (get balance2 channel) tx-sender (get participant2 channel))))
    
    (map-set channels
      { channel-id: channel-id }
      (merge channel { state: "CLOSED" })
    )
    
    (ok true)
  )
)

(define-public (dispute-channel (channel-id (buff 32)) (proposed-balance1 uint) (proposed-balance2 uint) (nonce uint) (signature (buff 65)))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
  )
    (asserts! (is-eq (get state channel) "OPEN") ERR-CHANNEL-CLOSED)
    (asserts! (> nonce (get nonce channel)) ERR-INVALID-STATE)
    (try! (validate-signature channel-id (+ proposed-balance1 proposed-balance2) nonce signature))
    
    (map-set channels
      { channel-id: channel-id }
      (merge channel {
        balance1: proposed-balance1,
        balance2: proposed-balance2,
        nonce: nonce,
        state: "DISPUTED"
      })
    )
    
    (ok true)
  )
)

(define-public (resolve-dispute (channel-id (buff 32)))
  (let (
    (channel (unwrap! (map-get? channels { channel-id: channel-id }) ERR-CHANNEL-NOT-FOUND))
  )
    (asserts! (is-eq (get state channel) "DISPUTED") ERR-INVALID-STATE)
    (asserts! (>= block-height (+ (var-get dispute-timeout) (get dispute-block channel))) ERR-INVALID-STATE)
    
    (try! (as-contract (stx-transfer? (get balance1 channel) tx-sender (get participant1 channel))))
    (try! (as-contract (stx-transfer? (get balance2 channel) tx-sender (get participant2 channel))))
    
    (map-set channels
      { channel-id: channel-id }
      (merge channel { state: "CLOSED" })
    )
    
    (ok true)
  )
)

;; Read-only Functions
(define-read-only (get-channel-info (channel-id (buff 32)))
  (map-get? channels { channel-id: channel-id })
)

(define-read-only (get-participant-channels (participant principal))
  (map-get? participant-channels { participant: participant })
)

;; Error Handling
(define-public (handle-error (error (response bool uint)))
  (match error
    success (ok success)
    error (begin
      (print (concat "Error: " (uint-to-buff error)))
      (err error)
    )
  )
)

;; Constants for dispute resolution
(define-data-var dispute-timeout uint u100) ;; Number of blocks for dispute resolution

;; Initialize contract
(begin
  (print "Dynamic Payment Channel Network contract initialized")
)