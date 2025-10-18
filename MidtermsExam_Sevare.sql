-- Enable pgcrypto for UUID generation 
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- USERS
CREATE TABLE users (
    user_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    full_name VARCHAR(100),
    bio TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- POSTS
CREATE TABLE posts (
    post_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    content TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- COMMENTS
CREATE TABLE comments (
    comment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id UUID NOT NULL REFERENCES posts(post_id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    content TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- LIKES
CREATE TABLE likes (
    like_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    post_id UUID REFERENCES posts(post_id) ON DELETE CASCADE,
    comment_id UUID REFERENCES comments(comment_id) ON DELETE CASCADE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_like_target CHECK (
        (post_id IS NOT NULL AND comment_id IS NULL)
        OR (post_id IS NULL AND comment_id IS NOT NULL)
    )
);

-- FOLLOWERS
CREATE TABLE followers (
    follower_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    following_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    followed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (follower_id, following_id),
    CONSTRAINT chk_self_follow CHECK (follower_id <> following_id)
);

-- NOTIFICATIONS
CREATE TABLE notifications (
    notification_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,   -- receiver
    actor_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,  -- trigger
    type VARCHAR(20) CHECK (type IN ('like', 'comment', 'follow', 'post')) NOT NULL,
    reference_id UUID NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    is_read BOOLEAN DEFAULT FALSE
);


-- NOTIFICATION FUNCTION

CREATE OR REPLACE FUNCTION create_notification(
    p_user_id INT,      -- receiver
    p_actor_id INT,     -- initiator
    p_type VARCHAR,
    p_reference_id INT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Avoid notifying self (e.g., liking own post)
    IF p_user_id <> p_actor_id THEN
        INSERT INTO notifications (user_id, actor_id, type, reference_id)
        VALUES (p_user_id, p_actor_id, p_type, p_reference_id);
    END IF;
END;
$$;

-- TRIGGER FUNCTIONS

-- Function: Create notification dynamically
CREATE OR REPLACE FUNCTION create_notification()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_TABLE_NAME = 'likes' THEN
        INSERT INTO notifications (user_id, actor_id, type, reference_id)
        SELECT 
            CASE 
                WHEN NEW.post_id IS NOT NULL THEN p.user_id
                ELSE c.user_id
            END,
            NEW.user_id,
            'like',
            COALESCE(NEW.post_id, NEW.comment_id)
        FROM posts p
        LEFT JOIN comments c ON c.comment_id = NEW.comment_id
        WHERE p.post_id = NEW.post_id OR c.comment_id = NEW.comment_id;

    ELSIF TG_TABLE_NAME = 'comments' THEN
        INSERT INTO notifications (user_id, actor_id, type, reference_id)
        SELECT p.user_id, NEW.user_id, 'comment', NEW.comment_id
        FROM posts p WHERE p.post_id = NEW.post_id;

    ELSIF TG_TABLE_NAME = 'followers' THEN
        INSERT INTO notifications (user_id, actor_id, type, reference_id)
        VALUES (NEW.following_id, NEW.follower_id, 'follow', NEW.following_id);

    ELSIF TG_TABLE_NAME = 'posts' THEN
        -- Optional: Notify followers when a user posts something
        INSERT INTO notifications (user_id, actor_id, type, reference_id)
        SELECT f.follower_id, NEW.user_id, 'post', NEW.post_id
        FROM followers f WHERE f.following_id = NEW.user_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- TRIGGERS

-- Trigger for likes
CREATE TRIGGER trg_like_notification
AFTER INSERT ON likes
FOR EACH ROW EXECUTE FUNCTION create_notification();

-- Trigger for comments
CREATE TRIGGER trg_comment_notification
AFTER INSERT ON comments
FOR EACH ROW EXECUTE FUNCTION create_notification();

-- Trigger for followers
CREATE TRIGGER trg_follow_notification
AFTER INSERT ON followers
FOR EACH ROW EXECUTE FUNCTION create_notification();

-- Trigger for posts (optional)
CREATE TRIGGER trg_post_notification
AFTER INSERT ON posts
FOR EACH ROW EXECUTE FUNCTION create_notification();

INSERT INTO users (username, email, password_hash, full_name, bio)
VALUES
('eleijah', 'eleijah@example.com', 'hashed_pw_eleijah', 'Eleijah Sevare', 
 'I love exploring data and late-night stargazing sessions.'),
('luna', 'luna@example.com', 'hashed_pw_luna', 'Luna Cortez', 
 'Ganahan ko mag-code sa buntag ug mag-inom og kape sa hapon.'),
('hannah', 'hannah@example.com', 'hashed_pw_hannah', 'Hannah Reyes', 
 'Mahilig ako sa design at sa mga bagay na creative talaga.'),
('kai', 'kai@example.com', 'hashed_pw_kai', 'Kai Fernandez', 
 'Building apps that make people’s lives easier keeps me motivated.'),
('aria', 'aria@example.com', 'hashed_pw_aria', 'Aria Lim', 
 'Usahay ganahan ra ko maglakaw-lakaw dala akong camera, chill kaayo.'),
('noah', 'noah@example.com', 'hashed_pw_noah', 'Noah Garcia', 
 'Gustong-gusto ko yung biyahe kahit malayo basta may magandang tanawin.'),
('mia', 'mia@example.com', 'hashed_pw_mia', 'Mia Cruz', 
 'Remote work gives me freedom, and I love that lifestyle.'),
('leo', 'leo@example.com', 'hashed_pw_leo', 'Leo Tan', 
 'Coder ko pero gamer pud, mao bitaw walay tulog usahay.'),
('sofia', 'sofia@example.com', 'hashed_pw_sofia', 'Sofia Ramos', 
 'Masaya ako kapag nakikita kong maganda yung design na ginawa ko.'),
('ethan', 'ethan@example.com', 'hashed_pw_ethan', 'Ethan Navarro', 
 'Always curious, always learning something new in tech.');



CREATE OR REPLACE PROCEDURE add_post(p_username TEXT, p_content TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
BEGIN
    -- Get the user_id of the username
    SELECT user_id INTO v_user_id
    FROM users
    WHERE username = p_username;

    -- Check if user exists
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User "%" not found.', p_username;
    END IF;

    -- Insert the post
    INSERT INTO posts (user_id, content)
    VALUES (v_user_id, p_content);

    RAISE NOTICE 'Post created for user "%".', p_username;
END;
$$;

CALL add_post('eleijah', 'Just launched my new data visualization project! 🚀');
CALL add_post('luna', 'Morning brew ☕ and some code review.');
CALL add_post('hannah', 'UI concept for our next project 💡');


CREATE OR REPLACE PROCEDURE add_comment(
    p_commenter_username TEXT,
    p_post_content_snippet TEXT,
    p_comment_text TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_post_id UUID;
BEGIN
    -- Get user_id of the commenter
    SELECT user_id INTO v_user_id
    FROM users
    WHERE username = p_commenter_username;

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'User "%" not found.', p_commenter_username;
    END IF;

    -- Find the post_id using partial content match
    SELECT post_id INTO v_post_id
    FROM posts
    WHERE content ILIKE '%' || p_post_content_snippet || '%'
    LIMIT 1;

    IF v_post_id IS NULL THEN
        RAISE EXCEPTION 'No post found matching snippet: "%".', p_post_content_snippet;
    END IF;

    -- Insert the comment
    INSERT INTO comments (post_id, user_id, content)
    VALUES (v_post_id, v_user_id, p_comment_text);

    RAISE NOTICE 'Comment added by "%" on post "%".', p_commenter_username, p_post_content_snippet;
END;
$$;
CALL add_comment('luna', 'data visualization', 'Looks amazing, Eleijah! 🔥');
CALL add_comment('hannah', 'brew', 'Need that coffee recipe ☕');


CREATE OR REPLACE PROCEDURE add_like(
    p_liker_username TEXT,
    p_post_snippet TEXT,
    p_mode TEXT DEFAULT 'single'  -- 'single' or 'everyone_except'
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_user_id UUID;
    v_post_id UUID;
BEGIN
    -- Find the post to like
    SELECT post_id INTO v_post_id
    FROM posts
    WHERE content ILIKE '%' || p_post_snippet || '%'
    LIMIT 1;

    IF v_post_id IS NULL THEN
        RAISE EXCEPTION 'No post found matching snippet "%".', p_post_snippet;
    END IF;

    -- Mode 1: single user like
    IF p_mode = 'single' THEN
        SELECT user_id INTO v_user_id
        FROM users
        WHERE username = p_liker_username;

        IF v_user_id IS NULL THEN
            RAISE EXCEPTION 'User "%" not found.', p_liker_username;
        END IF;

        INSERT INTO likes (user_id, post_id)
        VALUES (v_user_id, v_post_id)
        ON CONFLICT DO NOTHING;

        RAISE NOTICE 'User "%" liked post "%".', p_liker_username, p_post_snippet;

    -- Mode 2: everyone except a given user likes the post for testing purposes (tapulan ko)
    ELSIF p_mode = 'everyone_except' THEN
        INSERT INTO likes (user_id, post_id)
        SELECT u.user_id, v_post_id
        FROM users u
        WHERE u.username <> p_liker_username
        ON CONFLICT DO NOTHING;

        RAISE NOTICE 'All users except "%" liked post "%".', p_liker_username, p_post_snippet;

    ELSE
        RAISE EXCEPTION 'Invalid mode: %. Use "single" or "everyone_except".', p_mode;
    END IF;
END;
$$;

CALL add_like('eleijah', 'data visualization', 'everyone_except');
CALL add_like('luna', 'brew', 'everyone_except');
CALL add_like('luna', 'ui', 'single');


-- PROCEDURE: Add follower
CREATE OR REPLACE PROCEDURE add_follower(
    p_follower_username TEXT,
    p_following_username TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_follower_id UUID;
    v_following_id UUID;
BEGIN
    -- Get the follower user_id
    SELECT user_id INTO v_follower_id
    FROM users
    WHERE username = p_follower_username;

    IF v_follower_id IS NULL THEN
        RAISE EXCEPTION 'Follower "%" not found.', p_follower_username;
    END IF;

    -- Get the following user_id
    SELECT user_id INTO v_following_id
    FROM users
    WHERE username = p_following_username;

    IF v_following_id IS NULL THEN
        RAISE EXCEPTION 'User to follow "%" not found.', p_following_username;
    END IF;

    -- Prevent self-follow
    IF v_follower_id = v_following_id THEN
        RAISE EXCEPTION 'User "%" cannot follow themselves.', p_follower_username;
    END IF;

    -- Insert follow relationship if not existing
    INSERT INTO followers (follower_id, following_id)
    VALUES (v_follower_id, v_following_id)
    ON CONFLICT DO NOTHING;

    RAISE NOTICE 'User "%" now follows "%".', p_follower_username, p_following_username;
END;
$$;


CALL add_follower('luna', 'eleijah');
CALL add_follower('hannah', 'eleijah');
CALL add_follower('kai', 'eleijah');
CALL add_follower('aria', 'luna');
CALL add_follower('noah', 'hannah');
CALL add_follower('mia', 'kai');
CALL add_follower('leo', 'aria');
CALL add_follower('sofia', 'noah');
CALL add_follower('ethan', 'eleijah');

-- check notifs 
-- SELECT * from notifications

SELECT 
    p.post_id,
    u.username AS author,
    p.content,
    p.created_at
FROM posts p
JOIN users u ON p.user_id = u.user_id
ORDER BY p.created_at DESC;

SELECT 
    c.comment_id,
    cu.username AS commenter,
    p.content AS post_content,
    pu.username AS post_author,
    c.content AS comment_text,
    c.created_at
FROM comments c
JOIN users cu ON c.user_id = cu.user_id
JOIN posts p ON c.post_id = p.post_id
JOIN users pu ON p.user_id = pu.user_id
ORDER BY c.created_at DESC;

SELECT 
    l.like_id,
    u.username AS liker,
    COALESCE(p.content, c.content) AS liked_content,
    CASE 
        WHEN l.post_id IS NOT NULL THEN 'Post'
        WHEN l.comment_id IS NOT NULL THEN 'Comment'
    END AS liked_type,
    l.created_at
FROM likes l
JOIN users u ON l.user_id = u.user_id
LEFT JOIN posts p ON l.post_id = p.post_id
LEFT JOIN comments c ON l.comment_id = c.comment_id
ORDER BY l.created_at DESC;



SELECT 
    f2.username AS follower,
    t2.username AS following,
    f.followed_at
FROM followers f
JOIN users f2 ON f.follower_id = f2.user_id
JOIN users t2 ON f.following_id = t2.user_id
ORDER BY f2.username, f.followed_at DESC;


