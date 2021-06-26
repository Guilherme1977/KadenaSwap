(enforce-pact-version "4.0")
(describe-keyset "init-dev-admin")

(ns.write-registry (read-msg 'dao-ns) (keyset-ref-guard 'dao-ns-admin) true)
(define-namespace
  (read-msg 'dao-ns)
  (keyset-ref-guard 'dao-ns-user)
  (keyset-ref-guard 'dao-ns-admin)
)

(namespace (read-msg 'dao-ns))

(module auto-guards GOV
  (defcap GOV () (enforce false "no upgrades"))

  (defun guard-one:guard (gs:[guard])
    "Evaluates guards in a pure-context, does not short curcuit. \
    \Impure caps that the guards depend on must be triggered earlier in the tx. \
    \`prep-impure-module-admin-cap` can be used for this."
    (create-user-guard (enforce-one-guard gs)))

  (defun enforce-one-guard (gs:[guard])
    (let ((rs (map (try-wrap-enforce-guard) gs)))
      (enforce (< 0 (length (filter (= true) rs))) "all guards failed")
    ))

  (defun try-wrap-enforce-guard (g:guard)
    (try false (enforce-guard g)))

  (defun prep-impure-module-admin-cap:bool (t:table)
    "By attempting to access a module's internal table, we trip the module admin cap. \
    \Run this before `guard-one` is called to execute any module governance caps \
    \and put them in scope for the subsequent PURE call to `guard-one`"
    (take 1 (keys t))
    true))

(module init GOVERNANCE
  @doc
  "This is the start of the KDA DAO, not the end. \
  \It's not even something that should set a precedence. \
  \It intentionally doesn't incentivize participation. \
  \It doesn't even have a function to de-stake. \
  \Instead a community approved(ish) contract upgrade is needed to add functionality. \
  \The goal is to get KDA's guardians and ambassadors together, and make something better. \
  \Guardians are the stakers, with governance rights to approve and apply upgrades. \
  \Proposed upgrades have an APPROVAL_COOLDOWN days cooldown before they can be voted on and applied. \
  \Proposals have APPROVAL_TIMEOUT days to be applied, and need to be re-submitted thereafter. \
  \During this period, ambassadors can exercise their oversite: \
  \a majority vote by the ambassadors can freeze the DAO for FREEZE_TIMEOUT days. \
  \Guardians can add/deactivate/reactivate ambassadors. \
  \A DEACTIVATE_COOLDOWN avoids a red wedding. "

  (use util.guards)
  (use dao.auto-guards)
  (defun btwn-incl:bool (start:time end:time ts:time)
    (enforce (>= end start) (format "bounding start {} must come before end {}" [start end]))
    (and (>= ts start) (<= ts end)))



  (defconst DAO_MODULE_NAME "init")
  (defconst DAO_ACCT_NAME "init") ; we'll change this
  (defun dao-acct-balance () (coin.get-balance DAO_ACCT_NAME))
  (defcap INTERNAL ()
    "mark some functions as internal only"
    true)

  ; Approved upgrades need to be at least this old to occur.
  ; This gives the ambassadors time to respond
  (defconst APPROVAL_COOLDOWN (days 1))

  ; Approvals are on the clock
  (defconst APPROVAL_TIMEOUT (days 3))

  ; Min time between deactivations
  (defconst DEACTIVATE_COOLDOWN (days 1))

  ; Max time a freeze can exist for
  (defconst FREEZE_TIMEOUT (days 7))

  ; Every guardian needs to escrow this much to
  (defconst GUARDIAN_KDA_REQUIRED 500000.0)

  ; ----
  ; DAO State
  (defconst DAO_STATE_KEY "state")
  (defschema dao-state
    guardian-count:integer
    ambassador-count:integer
    dao-frozen-until:time
    last-ambassador-deactivation:time
    proposed-upgrade-hash:string
    proposed-upgrade-time:time)
  (deftable state:{dao-state})
  (defun init-state:string ()
    (let ((default-time (add-time (chain-time) (days -7))))
      ; insert fails if key exists, so this only runs once
      (insert state DAO_STATE_KEY
          {'guardian-count:0
          ,'ambassador-count:0
          ,'dao-frozen-until:default-time
          ,'last-ambassador-deactivation:default-time
          ,'proposed-upgrade-hash:""
          ,'proposed-upgrade-time:default-time})))
  (defun view-state:object{dao-state} ()
    (read state DAO_STATE_KEY))

  (defun adjust-ambassador-count:bool (adjustment:integer)
    (require-capability (INTERNAL))
    (enforce (= (abs adjustment) 1) "Adjustment is 1 at a time")
    (let* ((prev-state (read state DAO_STATE_KEY))
           (prev-cnt (at 'ambassador-count prev-state))
           (x (+ {'ambassador-count:(+ prev-cnt adjustment)} prev-state)))
      (write state DAO_STATE_KEY x))
    true)
  (defun adjust-guardian-count:bool (adjustment:integer)
    (require-capability (INTERNAL))
    (enforce (= (abs adjustment) 1) "Adjustment is 1 at a time")
    (with-read state DAO_STATE_KEY {'guardian-count:=cnt}
      (update state DAO_STATE_KEY
        {'guardian-count: (+ adjustment cnt)}))
    true)

  (defun is-dao-frozen:bool ()
    ; check the time of tx vs state.frozenuntil... but I think this can be done better via a guard
    (with-read state DAO_STATE_KEY {"dao-frozen-until":=frz-time}
        (enforce (> (chain-time) frz-time) "DAO is Frozen"))
    false)

  ; ----
  ; Guardians are the init's actors, the entites that will actually do things like run the bridge and upgrade the dao
  (defschema guardian
      k:string
      guard:guard
      moderate-guard:guard
      committed-kda:decimal
      approved-hash:string
      approved-date:time)
  (deftable guardians:{guardian})
  (defcap GUARDIAN (acct:string)
    (is-dao-frozen)
    (with-read guardians acct
      {"guard":=guard}
      (enforce-guard guard)))
  (defun view-guardians ()
      (map (read guardians) (keys guardians)))
  (defun is-guardian:bool (guardian:string)
    (with-capability (GUARDIAN guardian)
      true))
  (defun rotate-guardian:bool (guardian:string new-guard:guard)
    (with-capability (GUARDIAN guardian)
      (update guardians guardian {"guard": new-guard})
      true))

  (defun register-guardian:bool (acct:string guard:guard moderate-guard:guard)
    (enforce (>= (length acct) 3) "Guardian name too short")
    (with-capability (INTERNAL)
      (coin.transfer acct DAO_ACCT_NAME GUARDIAN_KDA_REQUIRED)
      (insert guardians acct
        {"k":acct
        ,"guard":guard
        ,"moderate-guard":moderate-guard
        ,"committed-kda":GUARDIAN_KDA_REQUIRED
        ,"approved-hash":""
        ,"approved-date":(chain-time)})
      (adjust-guardian-count 1)))

  ; For now, registration is a one-way street
  (defun unregister-guardian (acct:string)
    (enforce false
      (format "{} needs to be upgraded to enable withdrawls" [DAO_MODULE_NAME])))

  (defun propose-dao-upgrade (acct:string hsh:string)
    (with-capability (GUARDIAN acct)
      ; should we limit the frequency of proposals?
      ; for now, we just trust guardians to not be griefers
      (update state DAO_STATE_KEY
        {"proposed-upgrade-hash":hsh
        ,"proposed-upgrade-time":(chain-time)}))
     (guardian-approve-hash acct hsh)
     true)

  (defun guardian-approve-hash:bool (acct:string hsh:string)
    (with-capability (GUARDIAN acct)
      (with-read state DAO_STATE_KEY {'proposed-upgrade-hash:=prp-hsh}
        (enforce (= prp-hsh hsh)
          (format "Upgrade hash mismatch: {} vs {}" [prp-hsh hsh])))
      (update guardians acct
        {"approved-hash":hsh
        ,"approved-date":(chain-time)}))
    true)

  ; ----
  ; Ambassadors can lock things up (table flip)
  (defschema ambassador
      k:string
      guard:guard
      active:bool
      voted-to-freeze:time)
  (deftable ambassadors:{ambassador})
  (defcap AMBASSADOR (acct:string)
    (with-read ambassadors acct
      {"guard":=guard, "active":=active}
      (enforce-guard guard)
      (enforce active (format "Ambassador '{}' is not active" [acct]))))
  (defun view-ambassadors ()
      (map (read ambassadors) (keys ambassadors)))
  (defun is-ambassador:bool (ambassador:string)
    (with-capability (AMBASSADOR ambassador)
      (with-read ambassadors ambassador {"active":= active}
        (enforce active (format "{} is inactive" [ambassador]))))
    true)
  (defun rotate-ambassador:bool (ambassador:string new-guard:guard)
    (with-capability (AMBASSADOR ambassador)
      (update ambassadors ambassador {"guard": new-guard})
      true))

  (defun register-ambassador:bool (guardian:string acct:string guard:guard)
    (enforce (>= (length acct) 3) "Ambassador name too short")
    (with-capability (GUARDIAN guardian)
      (insert ambassadors acct
              {"k":acct
              ,"guard":guard
              ,"active":true
              ,"voted-to-freeze":(time "2000-01-01T12:00:00Z")})
      (with-capability (INTERNAL)
        (adjust-ambassador-count 1)))
      true)
  (defun deactivate-ambassador:bool (guardian:string ambassador:string)
  @doc "disable an ambassador, with a rate limit of DEACTIVATE_COOLDOWN"
    (with-capability (GUARDIAN guardian)
      (let ((lst-deactivate (at 'last-ambassador-deactivation (read state DAO_STATE_KEY))))
        (enforce (> (chain-time) (add-time lst-deactivate DEACTIVATE_COOLDOWN)) "Deactivate Cooldown Failure")
        (update state DAO_STATE_KEY {"last-ambassador-deactivation":(chain-time)})
        (update ambassadors ambassador {"active":false}))
      (with-capability (INTERNAL)
        (adjust-ambassador-count -1)))
      true)
  (defun reactivate-ambassador:bool (guardian:string ambassador:string)
    (with-capability (GUARDIAN guardian)
      (update ambassadors ambassador {"active":true})
      (with-capability (INTERNAL)
        (adjust-ambassador-count 1)))
      true)


  ; ----
  ; Freeze the DAO
  (defun vote-to-freeze:bool (ambassador:string)
    (with-capability (AMBASSADOR ambassador)
      (update ambassadors ambassador {"voted-to-freeze":(chain-time)}))
    true)

  (defun freeze:string (ambassador:string)
  @doc "allow any ambassador to freeze the DAO, assuming that sufficent votes have been cast"
    (with-capability (AMBASSADOR ambassador)
    (let* ((live-ambs
              (map (at "voted-to-freeze")
              (select ambassadors ["voted-to-freeze"] (where 'active (= true)))))
           (ambs-cnt (length live-ambs))
           (ambs-voted-to-freeze (length (filter (btwn-incl (add-time (chain-time) (- APPROVAL_COOLDOWN)) (chain-time)) live-ambs)))
           (dao-frz-ts (add-time (chain-time) FREEZE_TIMEOUT)))
      (enforce (> (* 2 ambs-voted-to-freeze) ambs-cnt)
        (format "Majority vote failed: {} of {}" [ambs-voted-to-freeze ambs-cnt]))
      (is-dao-frozen) ; so it can't get called twice
      ; is this correct?
      (update state DAO_STATE_KEY
        {"dao-frozen-until": dao-frz-ts})
      (format "DAO now frozen until {}" [dao-frz-ts]))))


  ; ----
  ; Upgrade the DAO
  (defcap GOVERNANCE:bool ()
    ; remove this before mainnet
    (if (try false (enforce-guard 'init-dev-admin ))
      true
      (let ((f (is-dao-frozen))); if it's frozen, bail
        (check-hash-approval (tx-hash)))))

  (defun create-gov-guard:guard ()
  @doc "primarily for namespace usage"
    (create-module-guard DAO_ACCT_NAME))

  (defun check-hash-approval:bool (hsh:string)
  @doc "verify that the a given transaction hash has been approved by a majority of the guardians"
    (with-read state DAO_STATE_KEY
      {'proposed-upgrade-time:=prp-time
      ,'guardian-count:=grd-cnt}
      (enforce (>= (chain-time) (add-time prp-time APPROVAL_COOLDOWN))
        (format "Proposal still in cooldown" [(add-time prp-time APPROVAL_COOLDOWN)]))
      (enforce (< (chain-time) (add-time prp-time APPROVAL_TIMEOUT))
        (format "Proposal has timed out" [(add-time prp-time APPROVAL_COOLDOWN)]))
      (let*
         ((approvals (map (at 'approved-date )
           (select guardians (where 'approved-hash (= hsh)))))
         (valid-aprv-start (add-time (chain-time) (- APPROVAL_TIMEOUT)))
         (valid-approvals (length (filter (<= valid-aprv-start) approvals))))
        (enforce (> (* 2 valid-approvals) grd-cnt)
          (format "Upgrade not approved, {} of {} for {}"
            [valid-approvals grd-cnt hsh])))))

    ; ----
    ; Initialize the DAO
    (defun init:string ()
      (init-state)
      (enforce-guard 'init-dev-admin )
      (coin.create-account
        DAO_ACCT_NAME
        (create-module-guard DAO_ACCT_NAME)))

)

(create-table state)
(create-table ambassadors)
(create-table guardians)
(init.init)

(module forum GOVERNANCE

  (defconst FORUM_MODULE_NAME "forum")
  (defcap FORUM-INTERNAL ()
    "mark some functions as internal only"
    true)

  (defcap GOVERNANCE ()
    (with-read forum-state FORUM_STATE_KEY {'mjolnir-guard:=mjolnir}
      (enforce-guard mjolnir)))

  (defun create-forum-gov-guard:guard ()
  @doc "primarily for namespace usage"
    (create-module-guard FORUM_MODULE_NAME))


  (use util.guards)
  (use dao.init)

  ; ----
  ; DAO State
  (defconst FORUM_STATE_KEY "state")
  (defschema forum-state-obj
    next-forum-uuid:integer
    mjolnir-guard:guard)
  (deftable forum-state:{forum-state-obj})
  (defun view-forum-state ()
    (read forum-state FORUM_STATE_KEY))
  (defun init-forum-state:bool (mjolnir-guard:guard)
    (insert forum-state FORUM_STATE_KEY
        {'next-forum-uuid:0
        ,'mjolnir-guard:mjolnir-guard})
    true)
  (defcap MJOLNIR ()
    (with-read forum-state FORUM_STATE_KEY {'mjolnir-guard:=mjolnir}
      (enforce-guard mjolnir)))

  (defun rotate-mjolnir (guard:guard)
    (with-capability (MJOLNIR)
      (update forum-state FORUM_STATE_KEY {"mjolnir-guard":guard})))

  (defun forum-uuid:string ()
    (require-capability (FORUM-INTERNAL))
    (with-read forum-state FORUM_STATE_KEY {'next-forum-uuid:=i}
      (update forum-state FORUM_STATE_KEY {'next-forum-uuid: (+ 1 i)})
      (format "{}" [i])))

  ; ----
  ; members
  (defschema member-obj
    name:string
    guard:guard
    moderator:bool
    disabled:bool)
  (deftable members:{member-obj})
  (defun view-members ()
    (map (read members) (keys members)))
  (defcap MEMBER:bool (member:string)
    (with-read members member {"guard":=g ,"disabled":=disabled}
      (enforce (not disabled) (format "Member '{}' is disabled" [member]))
      (enforce-guard g))
    true)
  (defcap MODERATOR (member:string)
    (with-read members member
      {"guard":=g ,"disabled":=disabled, "moderator":= moderator}
      (enforce (not disabled) (format "Member '{}' is disabled" [member]))
      (enforce moderator (format "Member '{}' is not a moderator" [member]))
      (enforce-guard g))
    true)

  (defun become-moderator (guardian:string moderator-guard:guard)
    (is-guardian guardian)
    (insert members guardian
      {'name:guardian
      ,'guard:moderator-guard
      ,'moderator:true
      ,'disabled:false}))

  (defun become-member (ambassdor:string member-guard:guard)
    (is-ambassador ambassdor)
    (insert members ambassdor
      {'name:ambassdor
      ,'guard:member-guard
      ,'moderator:false
      ,'disabled:false}))

  (defun disable-member (moderator:string member:string)
    (log-mod-action moderator (format "Disabled: {}" [member]))
    (with-read members member
      {"disabled":=disabled, "moderator":=is-mod}
      (enforce (not is-mod) "Moderators cannot moderate other mods")
      (update members member {"disabled":true})))

  (defun enable-member (moderator:string member:string)
    (log-mod-action moderator (format "Enabled: {}" [member]))
    (with-read members member
      {"disabled":=disabled, "moderator":=is-mod}
      (enforce (not is-mod) "Moderators cannot moderate other mods")
      (update members member {"disabled":false})))

  (defun rotate-member (member:string guard:guard)
    (with-capability (MEMBER member)
      (update members member {"guard":guard})))

  (defun disable-moderator (moderator:string)
    (log-mjolnir-action (format "Disabled: {}" [moderator]))
    (update members moderator {"disabled":true}))

  (defun enable-moderator (moderator:string)
    (log-mjolnir-action (format "enabled: {}" [moderator]))
    (update members moderator {"disabled":false}))

  (defun mjolnir-write-member (member:string member-guard:guard is-moderator:bool)
    "use this to directly mutate members"
    (log-mjolnir-action (format "Creating new member: {}" [member]))
    (write members member
      {'name:member
      ,'guard:member-guard
      ,'moderator:is-moderator
      ,'disabled:false}))


  ; ----
  ; suggestion functionality

  (defconst MAXIMUM_TOPIC_HEADLINE_LENGTH 256)
  (defconst MAXIMUM_TOPIC_BODY_LENGTH 5000)
  (defconst MAXIMUM_COMMENT_BODY_LENGTH 2500)

  (defun validate-markdown (subj:string txt:string max:integer)
    (let ((txt-length (length txt)))
      (enforce
        (>= txt-length 3)
        (format
          "{} does not conform to the coin contract min length '{}': {}..."
          [subj, 3, (take 30 txt)]))
      (enforce
        (<= txt-length max)
        (format
          "{} does not conform to the coin contract max length '{}': {}..."
          [subj, max, (take 30 txt)]))))

  (defschema modlog
    author:string
    timestamp:time
    action:string)
  (deftable modlogs:{modlog})
  (defun view-modlogs ()
    (map (read modlogs) (keys modlogs)))
  (defun log-mod-action (author:string action:string)
    (with-capability (MODERATOR author)
      (with-capability (FORUM-INTERNAL)
        (let ((index (forum-uuid)))
          (insert modlogs index
            {'author: author
            ,'timestamp:(chain-time)
            ,'action: action})))))
  (defun log-mjolnir-action (action:string)
    (with-capability (MJOLNIR)
      (with-capability (FORUM-INTERNAL)
        (let ((index (forum-uuid)))
          (insert modlogs index
            {'author: "mjolnir"
            ,'timestamp:(chain-time)
            ,'action: action})))))

  (defschema comment
    index:string
    parent-index:string
    topic-index:string
    author:string
    timestamp:time
    modified:bool
    deleted:bool
    locked:bool
    body:string
    upvotes:[string]
    downvotes:[string]
    child-indexs:[string])
  (deftable comments:{comment})
  (defun view-comments ()
    (map (read comments) (keys comments)))
  (defun view-comment (comment-index:string)
    (with-read comments comment-index
        { 'index := index
        , 'parent-index := parent-index
        , 'author := author
        , 'timestamp := timestamp
        , 'modified := modified
        , 'deleted := deleted
        , 'locked := locked
        , 'body := body
        , 'upvotes := upvotes
        , 'downvotes := downvotes
        , 'child-indexs := child-indexs }
      { 'index : index
      , 'parent-index : parent-index
      , 'author : author
      , 'timestamp : timestamp
      , 'modified : modified
      , 'deleted : deleted
      , 'locked : locked
      , 'body : body
      , 'upvotes : upvotes
      , 'downvotes : downvotes
      , 'children : (map (read comments) child-indexs) }))

  (defschema topic
    index:string
    headline:string
    author:string
    timestamp:time
    modified:bool
    body:string
    deleted:bool
    locked:bool
    upvotes:[string]
    downvotes:[string]
    comment-indexs:[string]
    all-comments:[string])
  (deftable topics:{topic})
  (defun view-topic (topic-index)
    (with-read topics topic-index
        { 'index := index
        , 'headline := headline
        , 'author := author
        , 'timestamp := timestamp
        , 'modified := modified
        , 'body := body
        , 'deleted := deleted
        , 'locked := locked
        , 'upvotes := upvotes
        , 'downvotes := downvotes
        , 'comment-indexs := comment-indexs
        , 'all-comments := all-comments}
      { 'index : index
      , 'headline : headline
      , 'author : author
      , 'timestamp : timestamp
      , 'modified : modified
      , 'body : body
      , 'deleted : deleted
      , 'locked : locked
      , 'upvotes : upvotes
      , 'downvotes : downvotes
      , 'comment-indexs : comment-indexs
      , 'all-comments : (map (read comments) all-comments) }))
  (defun undeleted-topic-keys:[string] ()
    (sort
      (map (at 'index)
      (select topics [ 'index ] (where 'deleted (= false))))))
  (defun view-topics ()
    (map (view-topic) (undeleted-topic-keys)))
  (defun view-deleted-topics ()
    (select topics [ 'index 'headline ] (where 'deleted (= true))))
  (defun view-topic-raw (topic-index:string)
    (read topics topic-index))

  (defun post-topic:string (headline:string author:string body:string)
    (with-capability (MEMBER author)
      (validate-markdown "topic headline" headline MAXIMUM_TOPIC_HEADLINE_LENGTH)
      (validate-markdown "topic body" body MAXIMUM_TOPIC_BODY_LENGTH)
      (with-capability (FORUM-INTERNAL)
        (let ((index (forum-uuid)))
          (insert topics index
             { 'index : index
             , 'headline : headline
             , 'author : author
             , 'timestamp : (chain-time)
             , 'modified : false
             , 'body : body
             , 'deleted : false
             , 'locked : false
             , 'upvotes : []
             , 'downvotes : []
             , 'comment-indexs: []
             , 'all-comments: []})
          index))))

  (defun modify-topic:bool (index:string headline:string body:string)
    (with-read topics index
        { 'author := author
        , 'deleted := deleted
        , 'locked := locked }
      (enforce (and (not deleted) (not locked)) "Deleted/Locked posts can't be modified")
      (validate-markdown "topic headline" headline MAXIMUM_TOPIC_HEADLINE_LENGTH)
      (validate-markdown "topic body" body MAXIMUM_TOPIC_BODY_LENGTH)
      (with-capability (MEMBER author)
        (update topics index
           { 'headline : headline
           , 'timestamp : (chain-time)
           , 'modified : true
           , 'body : body })))
    true)

  (defun delete-topic:bool (guardian:string topic-index:string)
    (log-mod-action guardian (format "Deleting topic {}" [topic-index]))
    (update topics topic-index {'deleted:true})
    true)

  (defun undelete-topic:bool (guardian:string topic-index:string)
    (log-mod-action guardian (format "Undeleting topic {}" [topic-index]))
    (update topics topic-index {'deleted:false})
    true)

  (defun lock-comment (comment-index:string)
    (require-capability (FORUM-INTERNAL))
    (update comments comment-index {'locked:true})
    true)
  (defun unlock-comment (comment-index:string)
    (require-capability (FORUM-INTERNAL))
    (update comments comment-index {'locked:false})
    true)

  (defun lock-topic:bool (guardian:string topic-index:string)
    (log-mod-action guardian (format "Locking topic {}" [topic-index]))
      (update topics topic-index {'locked : true})
      (with-capability (FORUM-INTERNAL)
        (with-read topics topic-index {"all-comments":=all-comments}
          (map (lock-comment) all-comments)))
    true)

  (defun unlock-topic:bool (guardian:string topic-index:string)
    (log-mod-action guardian (format "Unlocking topic {}" [topic-index]))
      (with-read topics topic-index {'comment-indexs := comment-indexs}
        (update topics topic-index {'locked : false})
        (with-capability (FORUM-INTERNAL)
          (map (unlock-comment) comment-indexs)))
    true)

  (defun post-topic-comment:string (author:string body:string topic-index:string)
    (with-capability (MEMBER author)
      (validate-markdown "comment body" body MAXIMUM_COMMENT_BODY_LENGTH)
      (with-capability (FORUM-INTERNAL)
        (let ((index (forum-uuid)))
          (with-read topics topic-index
              {'comment-indexs := comment-indexs
              ,'all-comments := all-comments}
            (update topics topic-index
              {'comment-indexs: (+ comment-indexs [index])
              ,'all-comments: (+ all-comments [index])}))
          (insert comments index
             { 'index : index
             , 'parent-index : topic-index
             , 'topic-index : topic-index
             , 'author : author
             , 'timestamp : (chain-time)
             , 'modified : false
             , 'locked : false
             , 'body : body
             , 'deleted : false
             , 'upvotes : []
             , 'downvotes : []
             , 'child-indexs : [] })
          index))))

  (defun post-comment-comment:string (author:string body:string parent-index:string)
    (with-capability (MEMBER author)
      (validate-markdown "comment body" body MAXIMUM_COMMENT_BODY_LENGTH)
      (with-capability (FORUM-INTERNAL)
        (let ((index (forum-uuid)))
          (with-read comments parent-index
              {'child-indexs := child-indexs
              ,"topic-index" := topic-index}
            (with-read topics topic-index {'all-comments := all-comments}
            (update topics topic-index
              {'all-comments: (+ all-comments [index])})
            (update comments parent-index
              {'child-indexs: (+ child-indexs [index])})
            (insert comments index
               { 'index : index
               , 'parent-index : parent-index
               , 'topic-index : topic-index
               , 'author : author
               , 'timestamp : (chain-time)
               , 'modified : false
               , 'locked : false
               , 'body : body
               , 'deleted : false
               , 'upvotes : []
               , 'downvotes : []
               , 'child-indexs : [] })))
            index))))

  (defun modify-comment:bool (index:string body:string)
    (with-read comments index
        { 'author := author
        , 'deleted := deleted
        , 'locked := locked }
      (validate-markdown "comment body" body MAXIMUM_COMMENT_BODY_LENGTH)
      (enforce (and (not deleted) (not locked)) "Deleted/Locked comments can't be modified")
      (with-capability (MEMBER author)
        (update comments index
           { 'timestamp : (chain-time)
           , 'modified : true
           , 'body : body })))
    true)

  (defun delete-topic-comment:bool (guardian:string comment-index:string)
    (with-read comments comment-index {'parent-index := topic-index}
      (log-mod-action guardian (format "Deleted comment {} from topic {}" [comment-index topic-index]))
      (update comments comment-index {'deleted : true})
      (with-read topics topic-index
          {'all-comments := all-comments, 'comment-indexs := comment-indexs}
        (update topics topic-index
          {'comment-indexs : (filter (!= comment-index) comment-indexs)
          ,'all-comments : (filter (!= comment-index) all-comments)}
          )))
    true)

  (defun delete-comment-comment:bool (guardian:string comment-index:string)
    (with-read comments comment-index {'parent-index := parent-index}
      (log-mod-action guardian (format "Deleted comment {} from comment {}" [comment-index parent-index]))
      (update comments comment-index {'deleted : true})
      (with-read comments parent-index
          {'topic-index := topic-index, 'child-indexs := child-indexs}
        (with-read topics topic-index {'all-comments := all-comments}
          (update topics topic-index
            {'all-comments : (filter (!= comment-index) all-comments)})
          (update comments parent-index
            {'child-indexs : (filter (!= comment-index) child-indexs)}))))
    true)

  (defun vote-on-topic:bool (account:string topic-index:string vote:string)
    (with-capability (MEMBER account)
      (with-read topics topic-index {'upvotes:=upvotes, 'downvotes:=downvotes}
        (let ((vu (filter (!= account) upvotes))
              (vd (filter (!= account) downvotes)))
          (if (= vote "upvote")
              (update topics topic-index {'upvotes:(+ vu [account]), 'downvotes:vd})
          (if (= vote "downvote")
              (update topics topic-index {'upvotes:vu, 'downvotes:(+ vd [account])})
          (if (= vote "remove")
              (update topics topic-index {'upvotes:vu, 'downvotes:vd})
          ;else
              (format "for typecheck {}" [(enforce false "votes must be one of: ['upvote' 'downvote' 'remove']")])
    ))))))
    true)

  (defun vote-on-comment:bool (account:string comment-index:string vote:string)
    (with-capability (MEMBER account)
      (with-read comments comment-index {'upvotes:=upvotes, 'downvotes:=downvotes}
        (let ((vu (filter (!= account) upvotes))
              (vd (filter (!= account) downvotes)))
          (if (= vote "upvote")
              (update comments comment-index {'upvotes:(+ vu [account]), 'downvotes:vd})
          (if (= vote "downvote")
              (update comments comment-index {'upvotes:vu, 'downvotes:(+ vd [account])})
          (if (= vote "remove")
              (update comments comment-index {'upvotes:vu, 'downvotes:vd})
          ;else
              (format "for typecheck {}" [(enforce false "votes must be one of: ['upvote' 'downvote' 'remove']")])
    ))))))
    true)
  ;
  (defun init (mjolnir-guard:guard)
    (init-forum-state mjolnir-guard))
)


(create-table comments)
(create-table topics)
(create-table modlogs)
(create-table forum-state)
(create-table members)
(forum.init (read-keyset "mjolnir"))

(define-namespace
  (read-msg 'dao-ns)
  (auto-guards.guard-one [(create-gov-guard) (create-forum-gov-guard)])
  (keyset-ref-guard 'dao-ns-admin)
)