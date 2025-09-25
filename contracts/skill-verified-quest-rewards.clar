
;; title: skill-verified-quest-rewards
;; version: 1.0.0
;; summary: A smart contract for skill-verified quest rewards system
;; description: Allows users to create quests, complete them, and receive rewards upon oracle verification

;; Error constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_QUEST_NOT_FOUND (err u101))
(define-constant ERR_QUEST_EXPIRED (err u102))
(define-constant ERR_ALREADY_COMPLETED (err u103))
(define-constant ERR_INSUFFICIENT_FUNDS (err u104))
(define-constant ERR_INVALID_ORACLE (err u105))
(define-constant ERR_QUEST_INACTIVE (err u106))
(define-constant ERR_INVALID_REWARD (err u107))

;; Data variables
(define-data-var next-quest-id uint u1)
(define-data-var contract-balance uint u0)

;; Data maps
(define-map quests
  { quest-id: uint }
  {
    creator: principal,
    title: (string-ascii 64),
    description: (string-ascii 256),
    reward-amount: uint,
    expiry-block: uint,
    oracle: principal,
    active: bool,
    skill-type: (string-ascii 32)
  }
)

(define-map quest-completions
  { quest-id: uint, participant: principal }
  { completed: bool, completion-block: uint, verified: bool }
)

(define-map user-stats
  { user: principal }
  { quests-completed: uint, total-rewards: uint }
)

(define-map authorized-oracles
  { oracle: principal }
  { authorized: bool, reputation: uint }
)

;; Public functions
(define-public (create-quest 
  (title (string-ascii 64))
  (description (string-ascii 256))
  (reward-amount uint)
  (duration-blocks uint)
  (oracle principal)
  (skill-type (string-ascii 32)))
  (let (
    (quest-id (var-get next-quest-id))
    (expiry-block (+ stacks-block-height duration-blocks))
  )
    (asserts! (> reward-amount u0) ERR_INVALID_REWARD)
    (asserts! (>= (stx-get-balance tx-sender) reward-amount) ERR_INSUFFICIENT_FUNDS)
    (asserts! (is-oracle-authorized oracle) ERR_INVALID_ORACLE)
    
    (try! (stx-transfer? reward-amount tx-sender (as-contract tx-sender)))
    
    (map-set quests
      { quest-id: quest-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        reward-amount: reward-amount,
        expiry-block: expiry-block,
        oracle: oracle,
        active: true,
        skill-type: skill-type
      }
    )
    
    (var-set contract-balance (+ (var-get contract-balance) reward-amount))
    (var-set next-quest-id (+ quest-id u1))
    (ok quest-id)
  )
)

(define-public (complete-quest (quest-id uint))
  (let (
    (quest (unwrap! (map-get? quests { quest-id: quest-id }) ERR_QUEST_NOT_FOUND))
    (existing-completion (map-get? quest-completions { quest-id: quest-id, participant: tx-sender }))
  )
    (asserts! (get active quest) ERR_QUEST_INACTIVE)
    (asserts! (< stacks-block-height (get expiry-block quest)) ERR_QUEST_EXPIRED)
    (asserts! (is-none existing-completion) ERR_ALREADY_COMPLETED)
    
    (map-set quest-completions
      { quest-id: quest-id, participant: tx-sender }
      { completed: true, completion-block: stacks-block-height, verified: false }
    )
    
    (ok true)
  )
)

(define-public (verify-completion (quest-id uint) (participant principal))
  (let (
    (quest (unwrap! (map-get? quests { quest-id: quest-id }) ERR_QUEST_NOT_FOUND))
    (completion (unwrap! (map-get? quest-completions { quest-id: quest-id, participant: participant }) ERR_QUEST_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get oracle quest)) ERR_NOT_AUTHORIZED)
    (asserts! (get completed completion) ERR_QUEST_NOT_FOUND)
    (asserts! (not (get verified completion)) ERR_ALREADY_COMPLETED)
    
    (map-set quest-completions
      { quest-id: quest-id, participant: participant }
      (merge completion { verified: true })
    )
    
    (try! (as-contract (stx-transfer? (get reward-amount quest) tx-sender participant)))
    
    (let (
      (current-stats (default-to { quests-completed: u0, total-rewards: u0 }
                     (map-get? user-stats { user: participant })))
    )
      (map-set user-stats
        { user: participant }
        {
          quests-completed: (+ (get quests-completed current-stats) u1),
          total-rewards: (+ (get total-rewards current-stats) (get reward-amount quest))
        }
      )
    )
    
    (var-set contract-balance (- (var-get contract-balance) (get reward-amount quest)))
    (ok true)
  )
)

(define-public (authorize-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set authorized-oracles
      { oracle: oracle }
      { authorized: true, reputation: u100 }
    )
    (ok true)
  )
)

(define-public (revoke-oracle (oracle principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
    (map-set authorized-oracles
      { oracle: oracle }
      { authorized: false, reputation: u0 }
    )
    (ok true)
  )
)

(define-public (deactivate-quest (quest-id uint))
  (let (
    (quest (unwrap! (map-get? quests { quest-id: quest-id }) ERR_QUEST_NOT_FOUND))
  )
    (asserts! (is-eq tx-sender (get creator quest)) ERR_NOT_AUTHORIZED)
    (asserts! (get active quest) ERR_QUEST_INACTIVE)
    
    (map-set quests
      { quest-id: quest-id }
      (merge quest { active: false })
    )
    
    (try! (as-contract (stx-transfer? (get reward-amount quest) tx-sender (get creator quest))))
    (var-set contract-balance (- (var-get contract-balance) (get reward-amount quest)))
    (ok true)
  )
)

;; Read-only functions
(define-read-only (get-quest (quest-id uint))
  (map-get? quests { quest-id: quest-id })
)

(define-read-only (get-quest-completion (quest-id uint) (participant principal))
  (map-get? quest-completions { quest-id: quest-id, participant: participant })
)

(define-read-only (get-user-stats (user principal))
  (default-to { quests-completed: u0, total-rewards: u0 }
              (map-get? user-stats { user: user }))
)

(define-read-only (is-oracle-authorized (oracle principal))
  (default-to false
              (get authorized (map-get? authorized-oracles { oracle: oracle })))
)

(define-read-only (get-oracle-reputation (oracle principal))
  (default-to u0
              (get reputation (map-get? authorized-oracles { oracle: oracle })))
)

(define-read-only (get-active-quests-count)
  (- (var-get next-quest-id) u1)
)

(define-read-only (get-contract-balance)
  (var-get contract-balance)
)

(define-read-only (is-quest-expired (quest-id uint))
  (match (map-get? quests { quest-id: quest-id })
    quest (>= stacks-block-height (get expiry-block quest))
    true
  )
)

(define-read-only (can-complete-quest (quest-id uint) (participant principal))
  (match (map-get? quests { quest-id: quest-id })
    quest 
      (and 
        (get active quest)
        (< stacks-block-height (get expiry-block quest))
        (is-none (map-get? quest-completions { quest-id: quest-id, participant: participant }))
      )
    false
  )
)

