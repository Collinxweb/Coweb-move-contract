/// epochs_bounty::bounty
/// Escrow-based bounty board. A creator locks a SUI reward into a shared
/// Bounty object; a submitter claims it with a reference (Walrus/IPFS CID);
/// the creator approves and the escrow pays out atomically. No admin key,
/// no custodian — the Bounty object itself holds the funds.
module epochs_bounty::bounty {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use std::string::{Self, String};
    use std::option::{Self, Option};

    // ---- Status codes -------------------------------------------------
    const STATUS_OPEN: u8 = 0;
    const STATUS_SUBMITTED: u8 = 1;
    const STATUS_APPROVED: u8 = 2;
    const STATUS_EXPIRED: u8 = 3;

    // ---- Errors ---------------------------------------------------------
    const E_ZERO_REWARD: u64 = 0;
    const E_DEADLINE_IN_PAST: u64 = 1;
    const E_NOT_OPEN: u64 = 2;
    const E_PAST_DEADLINE: u64 = 3;
    const E_CREATOR_CANNOT_CLAIM: u64 = 4;
    const E_NOT_CREATOR: u64 = 5;
    const E_NOT_SUBMITTED: u64 = 6;
    const E_NO_SUBMITTER: u64 = 7;
    const E_NOT_YET_EXPIRED: u64 = 8;
    const E_NOT_RECLAIMABLE: u64 = 9;

    // ---- Object ---------------------------------------------------------
    struct Bounty has key, store {
        id: UID,
        creator: address,
        description: String,       // short text or a Walrus/IPFS CID
        reward: Balance<SUI>,       // escrowed funds live inside the object
        status: u8,
        submitter: Option<address>,
        deadline: u64,              // unix ms
        submission_ref: String,     // Walrus/IPFS CID or link to the submission
    }

    // ---- Events (indexed by the frontend / Supabase sync worker) --------
    struct BountyCreated has copy, drop {
        bounty_id: ID,
        creator: address,
        reward_amount: u64,
        deadline: u64,
    }

    struct ClaimSubmitted has copy, drop {
        bounty_id: ID,
        submitter: address,
        submission_ref: String,
    }

    struct BountyApproved has copy, drop {
        bounty_id: ID,
        submitter: address,
        reward_amount: u64,
    }

    struct BountyExpired has copy, drop {
        bounty_id: ID,
        refunded_to: address,
        reward_amount: u64,
    }

    // ---- Entry functions --------------------------------------------------

    /// Create a bounty and escrow the reward in the same transaction.
    public entry fun create_bounty(
        description: vector<u8>,
        reward: Coin<SUI>,
        deadline: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let amount = coin::value(&reward);
        assert!(amount > 0, E_ZERO_REWARD);
        assert!(deadline > clock::timestamp_ms(clock), E_DEADLINE_IN_PAST);

        let bounty = Bounty {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            description: string::utf8(description),
            reward: coin::into_balance(reward),
            status: STATUS_OPEN,
            submitter: option::none<address>(),
            deadline,
            submission_ref: string::utf8(b""),
        };

        event::emit(BountyCreated {
            bounty_id: object::id(&bounty),
            creator: bounty.creator,
            reward_amount: amount,
            deadline,
        });

        transfer::share_object(bounty);
    }

    /// Submit a claim against an open, non-expired bounty. Double-claim
    /// guard: once status flips to SUBMITTED, a second submit_claim call
    /// fails the status assertion below — atomically, no race window.
    public entry fun submit_claim(
        bounty: &mut Bounty,
        submission_ref: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(bounty.status == STATUS_OPEN, E_NOT_OPEN);
        assert!(clock::timestamp_ms(clock) <= bounty.deadline, E_PAST_DEADLINE);

        let sender = tx_context::sender(ctx);
        assert!(sender != bounty.creator, E_CREATOR_CANNOT_CLAIM);

        bounty.submitter = option::some(sender);
        bounty.submission_ref = string::utf8(submission_ref);
        bounty.status = STATUS_SUBMITTED;

        event::emit(ClaimSubmitted {
            bounty_id: object::id(bounty),
            submitter: sender,
            submission_ref: bounty.submission_ref,
        });
    }

    /// Creator-only. Releases the full escrowed reward to the recorded
    /// submitter. balance::withdraw_all drains the Balance<SUI> to zero in
    /// the same instruction that flips status to APPROVED — Move's object
    /// model means there is no external call in between the state change
    /// and the transfer, so there is no re-entrant window to exploit.
    public entry fun approve_and_release(
        bounty: &mut Bounty,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == bounty.creator, E_NOT_CREATOR);
        assert!(bounty.status == STATUS_SUBMITTED, E_NOT_SUBMITTED);
        assert!(option::is_some(&bounty.submitter), E_NO_SUBMITTER);

        let submitter = *option::borrow(&bounty.submitter);
        let amount = balance::value(&bounty.reward);
        let payout = coin::from_balance(balance::withdraw_all(&mut bounty.reward), ctx);

        bounty.status = STATUS_APPROVED;

        transfer::public_transfer(payout, submitter);

        event::emit(BountyApproved {
            bounty_id: object::id(bounty),
            submitter,
            reward_amount: amount,
        });
    }

    /// Creator-only escape hatch once the deadline has passed with no
    /// approved submission: refunds the escrow to the creator and marks
    /// the bounty EXPIRED so it can never be claimed or approved again.
    public entry fun reclaim_expired(
        bounty: &mut Bounty,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == bounty.creator, E_NOT_CREATOR);
        assert!(
            bounty.status == STATUS_OPEN || bounty.status == STATUS_SUBMITTED,
            E_NOT_RECLAIMABLE
        );
        assert!(clock::timestamp_ms(clock) > bounty.deadline, E_NOT_YET_EXPIRED);

        let amount = balance::value(&bounty.reward);
        let refund = coin::from_balance(balance::withdraw_all(&mut bounty.reward), ctx);
        bounty.status = STATUS_EXPIRED;

        transfer::public_transfer(refund, bounty.creator);

        event::emit(BountyExpired {
            bounty_id: object::id(bounty),
            refunded_to: bounty.creator,
            reward_amount: amount,
        });
    }

    // ---- Read-only helpers (for dev tooling / tests / dry-run calls) -----
    public fun status(bounty: &Bounty): u8 { bounty.status }
    public fun creator(bounty: &Bounty): address { bounty.creator }
    public fun deadline(bounty: &Bounty): u64 { bounty.deadline }
    public fun reward_amount(bounty: &Bounty): u64 { balance::value(&bounty.reward) }
    public fun submitter(bounty: &Bounty): Option<address> { bounty.submitter }
    public fun submission_ref(bounty: &Bounty): String { bounty.submission_ref }

    public fun status_open(): u8 { STATUS_OPEN }
    public fun status_submitted(): u8 { STATUS_SUBMITTED }
    public fun status_approved(): u8 { STATUS_APPROVED }
    public fun status_expired(): u8 { STATUS_EXPIRED }
}
