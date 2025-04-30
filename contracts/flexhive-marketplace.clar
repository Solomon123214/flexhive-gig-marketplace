;; flexhive-marketplace
;; This contract manages the FlexHive decentralized gig marketplace on Stacks.
;; It enables the full lifecycle of gig work from job listings to payments, including:
;; - Job listing creation and management
;; - Freelancer applications and hiring
;; - Escrow-based payment processing
;; - Dispute resolution
;; - Reputation tracking for all participants

;; ========== Error Codes ==========
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-LISTING-NOT-FOUND (err u101))
(define-constant ERR-LISTING-CLOSED (err u102))
(define-constant ERR-ALREADY-APPLIED (err u103))
(define-constant ERR-APPLICATION-NOT-FOUND (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-ALREADY-HIRED (err u106))
(define-constant ERR-NOT-HIRED (err u107))
(define-constant ERR-JOB-NOT-COMPLETED (err u108))
(define-constant ERR-DISPUTE-EXISTS (err u109))
(define-constant ERR-DISPUTE-NOT-FOUND (err u110))
(define-constant ERR-NOT-ARBITER (err u111))
(define-constant ERR-FEEDBACK-ALREADY-PROVIDED (err u112))
(define-constant ERR-INVALID-RATING (err u113))
(define-constant ERR-NOT-INVOLVED-IN-GIG (err u114))
(define-constant ERR-GIG-ALREADY-COMPLETED (err u115))

;; ========== Contract Variables ==========
;; Principal of the contract deployer, who has admin rights
(define-data-var contract-owner principal tx-sender)

;; Designated arbiters who can resolve disputes
(define-map arbiters principal bool)

;; Platform fee percentage (in basis points, e.g., 250 = 2.5%)
(define-data-var platform-fee-bps uint u250)

;; Total number of job listings (used for listing IDs)
(define-data-var listing-count uint u0)

;; Total number of disputes (used for dispute IDs)
(define-data-var dispute-count uint u0)

;; ========== Data Structures ==========
;; Job listing details
(define-map job-listings
  uint  ;; listing-id
  {
    client: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    category: (string-ascii 50),
    skills: (list 10 (string-ascii 30)),
    budget: uint,
    deadline: uint,  ;; Unix timestamp
    status: (string-ascii 20),  ;; "open", "in-progress", "completed", "cancelled"
    created-at: uint,           ;; Unix timestamp
    hired-freelancer: (optional principal)  ;; Set when a freelancer is hired
  }
)

;; Applications from freelancers to job listings
(define-map applications
  {listing-id: uint, freelancer: principal}
  {
    proposal: (string-utf8 500),
    bid-amount: uint,           ;; Amount freelancer is asking for
    status: (string-ascii 20),  ;; "pending", "accepted", "rejected"
    applied-at: uint            ;; Unix timestamp
  }
)

;; Track all applications for a specific listing
(define-map listing-applications
  uint  ;; listing-id
  (list 100 principal)  ;; List of freelancers who applied
)

;; Escrow information for active jobs
(define-map escrows
  uint  ;; listing-id
  {
    amount: uint,
    client: principal,
    freelancer: principal,
    released: bool,
    disputed: bool
  }
)

;; Dispute details
(define-map disputes
  uint  ;; dispute-id
  {
    listing-id: uint,
    client: principal,
    freelancer: principal,
    client-evidence: (string-utf8 1000),
    freelancer-evidence: (string-utf8 1000),
    resolved: bool,
    resolution: (optional (string-ascii 20)),  ;; "client", "freelancer", "split"
    resolution-details: (optional (string-utf8 500)),
    resolved-by: (optional principal),
    created-at: uint
  }
)

;; Listing-to-dispute mapping
(define-map listing-to-dispute
  uint  ;; listing-id
  uint  ;; dispute-id
)

;; User reputation data
(define-map user-reputation
  principal
  {
    jobs-completed: uint,
    jobs-cancelled: uint,
    total-earnings: uint,
    average-rating: uint,  ;; Out of 100 (e.g., 4.5 stars = 450)
    rating-count: uint,
    joined-at: uint
  }
)

;; Feedback for completed gigs
(define-map gig-feedback
  {listing-id: uint, reviewer: principal}
  {
    recipient: principal,
    rating: uint,           ;; 1-5, scaled by 100 (e.g., 4.5 stars = 450)
    comment: (string-utf8 500),
    created-at: uint
  }
)

;; ========== Private Functions ==========
;; Initialize default reputation for a new user
(define-private (init-user-reputation (user principal))
  (map-insert user-reputation user 
    {
      jobs-completed: u0,
      jobs-cancelled: u0,
      total-earnings: u0,
      average-rating: u0,
      rating-count: u0,
      joined-at: (get-block-info? time (- block-height u1))
    }
  )
)

;; Get user reputation, initializing if needed
(define-private (get-user-reputation (user principal))
  (match (map-get? user-reputation user)
    existing existing
    (begin
      (init-user-reputation user)
      (unwrap-panic (map-get? user-reputation user))
    )
  )
)

;; Update a user's average rating
(define-private (update-rating (user principal) (new-rating uint))
  (let (
    (reputation (get-user-reputation user))
    (current-avg (get average-rating reputation))
    (current-count (get rating-count reputation))
    (new-count (+ current-count u1))
    (new-avg (/ (+ (* current-avg current-count) new-rating) new-count))
  )
    (map-set user-reputation user 
      (merge reputation {
        average-rating: new-avg,
        rating-count: new-count
      })
    )
  )
)

;; Calculate platform fee for a given amount
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-bps)) u10000)
)

;; Check if principal is an authorized arbiter
(define-private (is-arbiter (user principal))
  (default-to false (map-get? arbiters user))
)

;; Get all applicants for a job listing
(define-private (get-applicants (listing-id uint))
  (default-to (list) (map-get? listing-applications listing-id))
)

;; Add an applicant to a job listing's applicant list
(define-private (add-applicant (listing-id uint) (freelancer principal))
  (let (
    (current-applicants (get-applicants listing-id))
  )
    (map-set listing-applications listing-id (append current-applicants freelancer))
  )
)

;; ========== Read-Only Functions ==========
;; Get listing details
(define-read-only (get-listing (listing-id uint))
  (map-get? job-listings listing-id)
)

;; Get application details
(define-read-only (get-application (listing-id uint) (freelancer principal))
  (map-get? applications {listing-id: listing-id, freelancer: freelancer})
)

;; Get all applications for a listing
(define-read-only (get-listing-applicants (listing-id uint))
  (get-applicants listing-id)
)

;; Get escrow details for a listing
(define-read-only (get-escrow (listing-id uint))
  (map-get? escrows listing-id)
)

;; Get dispute details
(define-read-only (get-dispute (dispute-id uint))
  (map-get? disputes dispute-id)
)

;; Get dispute for a listing
(define-read-only (get-listing-dispute (listing-id uint))
  (match (map-get? listing-to-dispute listing-id)
    dispute-id (map-get? disputes dispute-id)
    none
  )
)

;; Get user reputation information
(define-read-only (get-reputation (user principal))
  (some (get-user-reputation user))
)

;; Get feedback for a specific gig and reviewer
(define-read-only (get-feedback (listing-id uint) (reviewer principal))
  (map-get? gig-feedback {listing-id: listing-id, reviewer: reviewer})
)

;; Check if principal is contract owner
(define-read-only (is-contract-owner (caller principal))
  (is-eq caller (var-get contract-owner))
)

;; Get the current platform fee in basis points
(define-read-only (get-platform-fee-bps)
  (var-get platform-fee-bps)
)

;; ========== Public Functions ==========
;; Create a new job listing
(define-public (create-job-listing 
    (title (string-ascii 100))
    (description (string-utf8 1000))
    (category (string-ascii 50))
    (skills (list 10 (string-ascii 30)))
    (budget uint)
    (deadline uint)
  )
  (let (
    (listing-id (var-get listing-count))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Ensure deadline is in the future
    (asserts! (> deadline current-time) (err u120))
    
    ;; Create the new listing
    (map-set job-listings listing-id {
      client: tx-sender,
      title: title,
      description: description,
      category: category,
      skills: skills,
      budget: budget,
      deadline: deadline,
      status: "open",
      created-at: current-time,
      hired-freelancer: none
    })
    
    ;; Initialize empty applicants list
    (map-set listing-applications listing-id (list))
    
    ;; Increment the listing counter
    (var-set listing-count (+ listing-id u1))
    
    ;; Return the new listing ID
    (ok listing-id)
  )
)

;; Apply to a job listing
(define-public (apply-to-job
    (listing-id uint)
    (proposal (string-utf8 500))
    (bid-amount uint)
  )
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
  )
    ;; Check if listing is still open
    (asserts! (is-eq (get status listing) "open") ERR-LISTING-CLOSED)
    
    ;; Check if freelancer has already applied
    (asserts! (is-none (map-get? applications {listing-id: listing-id, freelancer: tx-sender})) ERR-ALREADY-APPLIED)
    
    ;; Create the application
    (map-set applications 
      {listing-id: listing-id, freelancer: tx-sender}
      {
        proposal: proposal,
        bid-amount: bid-amount,
        status: "pending",
        applied-at: current-time
      }
    )
    
    ;; Add freelancer to applicants list
    (add-applicant listing-id tx-sender)
    
    (ok true)
  )
)

;; Hire a freelancer for a job
(define-public (hire-freelancer (listing-id uint) (freelancer principal))
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (application (unwrap! (map-get? applications {listing-id: listing-id, freelancer: freelancer}) ERR-APPLICATION-NOT-FOUND))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (bid-amount (get bid-amount application))
  )
    ;; Check if sender is the client
    (asserts! (is-eq tx-sender (get client listing)) ERR-NOT-AUTHORIZED)
    
    ;; Check if listing is still open
    (asserts! (is-eq (get status listing) "open") ERR-LISTING-CLOSED)
    
    ;; Check if no freelancer has been hired yet
    (asserts! (is-none (get hired-freelancer listing)) ERR-ALREADY-HIRED)
    
    ;; Check if client has enough funds and transfer to escrow
    (asserts! (<= bid-amount (stx-get-balance tx-sender)) ERR-INSUFFICIENT-FUNDS)
    
    ;; Update application status
    (map-set applications 
      {listing-id: listing-id, freelancer: freelancer}
      (merge application {status: "accepted"})
    )
    
    ;; Update listing status and hired freelancer
    (map-set job-listings listing-id 
      (merge listing {
        status: "in-progress",
        hired-freelancer: (some freelancer)
      })
    )
    
    ;; Create escrow
    (map-set escrows listing-id {
      amount: bid-amount,
      client: tx-sender,
      freelancer: freelancer,
      released: false,
      disputed: false
    })
    
    ;; Transfer funds to contract (escrow)
    (stx-transfer? bid-amount tx-sender (as-contract tx-sender))
  )
)

;; Freelancer marks job as completed
(define-public (mark-job-completed (listing-id uint))
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (hired-freelancer (unwrap! (get hired-freelancer listing) ERR-NOT-HIRED))
  )
    ;; Check if sender is the hired freelancer
    (asserts! (is-eq tx-sender hired-freelancer) ERR-NOT-AUTHORIZED)
    
    ;; Check if job is in progress
    (asserts! (is-eq (get status listing) "in-progress") ERR-NOT-HIRED)
    
    ;; Update listing status
    (map-set job-listings listing-id 
      (merge listing {status: "pending-approval"})
    )
    
    (ok true)
  )
)

;; Client approves completed work and releases payment
(define-public (release-payment (listing-id uint))
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (escrow-data (unwrap! (map-get? escrows listing-id) ERR-NOT-HIRED))
    (amount (get amount escrow-data))
    (freelancer (get freelancer escrow-data))
    (platform-fee (calculate-platform-fee amount))
    (freelancer-amount (- amount platform-fee))
    (client (get client listing))
    (freelancer-reputation (get-user-reputation freelancer))
  )
    ;; Check if sender is the client
    (asserts! (is-eq tx-sender client) ERR-NOT-AUTHORIZED)
    
    ;; Check if escrow exists and is not already released or disputed
    (asserts! (and (not (get released escrow-data)) (not (get disputed escrow-data))) ERR-DISPUTE-EXISTS)
    
    ;; Update listing status
    (map-set job-listings listing-id 
      (merge listing {status: "completed"})
    )
    
    ;; Update escrow status
    (map-set escrows listing-id 
      (merge escrow-data {released: true})
    )
    
    ;; Update freelancer reputation
    (map-set user-reputation freelancer 
      (merge freelancer-reputation {
        jobs-completed: (+ (get jobs-completed freelancer-reputation) u1),
        total-earnings: (+ (get total-earnings freelancer-reputation) freelancer-amount)
      })
    )
    
    ;; Transfer payment to freelancer
    (as-contract (stx-transfer? freelancer-amount tx-sender freelancer))
    
    ;; Transfer platform fee to contract owner
    (as-contract (stx-transfer? platform-fee tx-sender (var-get contract-owner)))
    
    (ok true)
  )
)

;; Create a dispute for a job
(define-public (create-dispute (listing-id uint) (evidence (string-utf8 1000)))
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (escrow-data (unwrap! (map-get? escrows listing-id) ERR-NOT-HIRED))
    (client (get client escrow-data))
    (freelancer (get freelancer escrow-data))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (dispute-id (var-get dispute-count))
  )
    ;; Check if sender is either the client or the freelancer
    (asserts! (or (is-eq tx-sender client) (is-eq tx-sender freelancer)) ERR-NOT-AUTHORIZED)
    
    ;; Check if escrow exists and is not already released or disputed
    (asserts! (and (not (get released escrow-data)) (not (get disputed escrow-data))) ERR-DISPUTE-EXISTS)
    
    ;; Update escrow status
    (map-set escrows listing-id 
      (merge escrow-data {disputed: true})
    )
    
    ;; Create dispute
    (map-set disputes dispute-id {
      listing-id: listing-id,
      client: client,
      freelancer: freelancer,
      client-evidence: (if (is-eq tx-sender client) evidence ""),
      freelancer-evidence: (if (is-eq tx-sender freelancer) evidence ""),
      resolved: false,
      resolution: none,
      resolution-details: none,
      resolved-by: none,
      created-at: current-time
    })
    
    ;; Map listing to dispute
    (map-set listing-to-dispute listing-id dispute-id)
    
    ;; Update dispute counter
    (var-set dispute-count (+ dispute-id u1))
    
    (ok dispute-id)
  )
)

;; Add evidence to an existing dispute
(define-public (add-dispute-evidence (dispute-id uint) (evidence (string-utf8 1000)))
  (let (
    (dispute (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND))
    (client (get client dispute))
    (freelancer (get freelancer dispute))
  )
    ;; Check if sender is either the client or the freelancer
    (asserts! (or (is-eq tx-sender client) (is-eq tx-sender freelancer)) ERR-NOT-AUTHORIZED)
    
    ;; Check if dispute is not yet resolved
    (asserts! (not (get resolved dispute)) (err u121))
    
    ;; Update the appropriate evidence field
    (if (is-eq tx-sender client)
      (map-set disputes dispute-id (merge dispute {client-evidence: evidence}))
      (map-set disputes dispute-id (merge dispute {freelancer-evidence: evidence}))
    )
    
    (ok true)
  )
)

;; Resolve a dispute (arbiter only)
(define-public (resolve-dispute 
    (dispute-id uint) 
    (resolution (string-ascii 20)) 
    (details (string-utf8 500))
  )
  (let (
    (dispute (unwrap! (map-get? disputes dispute-id) ERR-DISPUTE-NOT-FOUND))
    (listing-id (get listing-id dispute))
    (escrow-data (unwrap! (map-get? escrows listing-id) ERR-NOT-HIRED))
    (amount (get amount escrow-data))
    (client (get client dispute))
    (freelancer (get freelancer dispute))
    (platform-fee (calculate-platform-fee amount))
    (freelancer-amount (- amount platform-fee))
    (client-amount amount)
  )
    ;; Check if sender is an arbiter
    (asserts! (is-arbiter tx-sender) ERR-NOT-ARBITER)
    
    ;; Check if dispute is not yet resolved
    (asserts! (not (get resolved dispute)) (err u122))
    
    ;; Update dispute as resolved
    (map-set disputes dispute-id 
      (merge dispute {
        resolved: true,
        resolution: (some resolution),
        resolution-details: (some details),
        resolved-by: (some tx-sender)
      })
    )
    
    ;; Update escrow as released
    (map-set escrows listing-id 
      (merge escrow-data {released: true})
    )
    
    ;; Update listing status
    (map-set job-listings listing-id 
      (merge (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND) 
        {status: "dispute-resolved"})
    )
    
    ;; Handle payment based on resolution
    (if (is-eq resolution "client")
      ;; If client wins, return funds to client
      (as-contract (stx-transfer? client-amount tx-sender client))
      (if (is-eq resolution "freelancer")
        (begin
          ;; If freelancer wins, send payment to freelancer and fee to owner
          (as-contract (stx-transfer? freelancer-amount tx-sender freelancer))
          (as-contract (stx-transfer? platform-fee tx-sender (var-get contract-owner)))
          
          ;; Update freelancer reputation
          (map-set user-reputation freelancer 
            (merge (get-user-reputation freelancer) {
              jobs-completed: (+ (get jobs-completed (get-user-reputation freelancer)) u1),
              total-earnings: (+ (get total-earnings (get-user-reputation freelancer)) freelancer-amount)
            })
          )
        )
        ;; If split (or other resolution), customize the distribution as defined in details
        (begin
          ;; Default to 50/50 split minus platform fee
          (as-contract (stx-transfer? (/ (- amount platform-fee) u2) tx-sender freelancer))
          (as-contract (stx-transfer? (/ amount u2) tx-sender client))
          (as-contract (stx-transfer? platform-fee tx-sender (var-get contract-owner)))
        )
      )
    )
    
    (ok true)
  )
)

;; Leave feedback for a completed gig
(define-public (leave-feedback 
    (listing-id uint) 
    (recipient principal) 
    (rating uint) 
    (comment (string-utf8 500))
  )
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (client (get client listing))
    (hired-freelancer (unwrap! (get hired-freelancer listing) ERR-NOT-HIRED))
    (current-time (unwrap-panic (get-block-info? time (- block-height u1))))
    (status (get status listing))
  )
    ;; Check if sender is either the client or the hired freelancer
    (asserts! (or (is-eq tx-sender client) (is-eq tx-sender hired-freelancer)) ERR-NOT-AUTHORIZED)
    
    ;; Check if sender is leaving feedback for the other party
    (asserts! (not (is-eq tx-sender recipient)) (err u123))
    
    ;; Check if the recipient was involved in this gig
    (asserts! (or (is-eq recipient client) (is-eq recipient hired-freelancer)) ERR-NOT-INVOLVED-IN-GIG)
    
    ;; Check if gig is completed or dispute resolved
    (asserts! (or (is-eq status "completed") (is-eq status "dispute-resolved")) ERR-JOB-NOT-COMPLETED)
    
    ;; Check if rating is valid (between 100-500, representing 1-5 stars)
    (asserts! (and (>= rating u100) (<= rating u500)) ERR-INVALID-RATING)
    
    ;; Check if feedback hasn't been left already
    (asserts! (is-none (map-get? gig-feedback {listing-id: listing-id, reviewer: tx-sender})) ERR-FEEDBACK-ALREADY-PROVIDED)
    
    ;; Store the feedback
    (map-set gig-feedback 
      {listing-id: listing-id, reviewer: tx-sender}
      {
        recipient: recipient,
        rating: rating,
        comment: comment,
        created-at: current-time
      }
    )
    
    ;; Update recipient's reputation
    (update-rating recipient rating)
    
    (ok true)
  )
)

;; Cancel a job listing (client only, if no freelancer hired)
(define-public (cancel-job-listing (listing-id uint))
  (let (
    (listing (unwrap! (map-get? job-listings listing-id) ERR-LISTING-NOT-FOUND))
    (client (get client listing))
    (status (get status listing))
  )
    ;; Check if sender is the client
    (asserts! (is-eq tx-sender client) ERR-NOT-AUTHORIZED)
    
    ;; Check if listing can be cancelled (only if open)
    (asserts! (is-eq status "open") (err u124))
    
    ;; Update listing status
    (map-set job-listings listing-id 
      (merge listing {status: "cancelled"})
    )
    
    (ok true)
  )
)

;; Add an arbiter (contract owner only)
(define-public (add-arbiter (arbiter principal))
  (begin
    ;; Check if sender is the contract owner
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Add the arbiter
    (map-set arbiters arbiter true)
    
    (ok true)
  )
)

;; Remove an arbiter (contract owner only)
(define-public (remove-arbiter (arbiter principal))
  (begin
    ;; Check if sender is the contract owner
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Remove the arbiter
    (map-delete arbiters arbiter)
    
    (ok true)
  )
)

;; Update platform fee (contract owner only)
(define-public (update-platform-fee (new-fee-bps uint))
  (begin
    ;; Check if sender is the contract owner
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Ensure fee is reasonable (max 10%)
    (asserts! (<= new-fee-bps u1000) (err u125))
    
    ;; Update the fee
    (var-set platform-fee-bps new-fee-bps)
    
    (ok true)
  )
)

;; Transfer contract ownership (current owner only)
(define-public (transfer-ownership (new-owner principal))
  (begin
    ;; Check if sender is the current contract owner
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Update the owner
    (var-set contract-owner new-owner)
    
    (ok true)
  )
)