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
    (channel-id (sha256 (concat (concat (serialize-principal tx-sender) (serialize-principal participant2)) (uint-to-buff block-height))))
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