-- =====================================================================
-- 오운완 (運動完) — 전체 스키마 복원 SQL
-- designed & built by GM
--
-- ★ 이 파일 하나로 Supabase DB를 처음부터 완전히 재구축할 수 있습니다.
--
-- 실행 순서 (위에서 아래로 한 번만)
--   1. 테이블 4종           : profiles / workout_records / rooms / room_members / invite_codes
--   2. RLS 정책             : 각 테이블 행 수준 보안
--   3. Storage 버킷 정책    : workout-attachments (Public)
--   4. 뷰                   : leaderboard
--   5. RPC 함수 7종         : room_leaderboard / room_leaderboard_month /
--                             my_rooms / create_room / join_room / leave_room /
--                             redeem_invite
--   6. 사진 자동 삭제 함수  : purge_old_workout_images (pg_cron)
--   7. 초대코드 초기 데이터 : 공용 코드 1개 예시
--
-- ⚠️  실행 전 준비사항
--   • Supabase 대시보드 > Database > Extensions 에서 pg_cron 켜기
--     (켜지 않으면 6번 스케줄 등록에서 에러 발생)
--   • Storage > Buckets 에서 'workout-attachments' 버킷을 Public으로 수동 생성
--     (버킷 자체는 SQL로 만들 수 없고 대시보드에서 직접 생성해야 합니다)
--   • Supabase Auth > Anonymous sign-ins 활성화
--     (설정 > Auth > 익명 로그인 허용 켜기)
-- =====================================================================


-- =====================================================================
-- 1. 테이블
-- =====================================================================

-- ---------------------------------------------------------------------
-- profiles: 사용자 프로필 (익명 로그인 user_id와 1:1 연결)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id          uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nickname    text        NOT NULL DEFAULT '익명',
  gender      text        NOT NULL DEFAULT 'm' CHECK (gender IN ('m', 'f')),
  avatar_id   text,                             -- 선택한 캐릭터 키 (예: 'm1', 'f3')
  profile_src text,                             -- 업로드한 프로필 사진 URL (Storage 경로)
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- workout_records: 운동 인증 기록 (인증 1건 = 1행)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.workout_records (
  id           bigint      PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id      uuid        NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  category     text,                             -- 유산소 / 근력·기타 / 구기종목
  workout_name text,                             -- 러닝, 헬스, 농구 등 (NULL이면 더미)
  duration     integer,                          -- 운동 시간(분)
  image_url    text,                             -- Storage 공개 URL (30일 후 NULL로 비워짐)
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- rooms: 운동방 (그룹)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.rooms (
  id         uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text  NOT NULL,                    -- 방 이름 (최대 20자)
  code       text  NOT NULL UNIQUE,             -- 6자리 대문자 초대 코드
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- room_members: 운동방 멤버십 (방 ↔ 유저 N:M)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.room_members (
  room_id    uuid NOT NULL REFERENCES public.rooms(id)    ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  joined_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (room_id, user_id)
);

-- ---------------------------------------------------------------------
-- invite_codes: 앱 진입용 초대코드 (운동방 코드와 별개)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.invite_codes (
  code        text        PRIMARY KEY,          -- 초대코드 (대문자 권장)
  label       text,                             -- 메모 (누구에게 준 코드인지 등)
  max_uses    int         DEFAULT NULL,         -- NULL = 무제한 / 숫자 = 최대 사용 횟수
  used_count  int         DEFAULT 0,
  active      boolean     DEFAULT true,
  created_at  timestamptz DEFAULT now()
);


-- =====================================================================
-- 2. RLS (Row Level Security) 정책
-- =====================================================================

-- profiles --
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "profiles_select_own" ON public.profiles;
CREATE POLICY "profiles_select_own" ON public.profiles
  FOR SELECT TO authenticated USING (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_insert_own" ON public.profiles;
CREATE POLICY "profiles_insert_own" ON public.profiles
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "profiles_update_own" ON public.profiles;
CREATE POLICY "profiles_update_own" ON public.profiles
  FOR UPDATE TO authenticated USING (auth.uid() = id);

-- workout_records --
ALTER TABLE public.workout_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "workout_records_select_own" ON public.workout_records;
CREATE POLICY "workout_records_select_own" ON public.workout_records
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "workout_records_insert_own" ON public.workout_records;
CREATE POLICY "workout_records_insert_own" ON public.workout_records
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);

-- rooms --
ALTER TABLE public.rooms ENABLE ROW LEVEL SECURITY;

-- 방 정보는 RPC 함수(SECURITY DEFINER)를 통해서만 읽기 → 직접 SELECT 차단
-- (RLS는 켜두되 허용 정책 없음 = 전체 차단)

-- room_members --
ALTER TABLE public.room_members ENABLE ROW LEVEL SECURITY;

-- 마찬가지로 RPC를 통해서만 접근
-- (직접 SELECT 차단)

-- invite_codes --
ALTER TABLE public.invite_codes ENABLE ROW LEVEL SECURITY;
-- SELECT 정책 없음 → anon이 코드 목록을 직접 열람 불가
-- redeem_invite() 함수(SECURITY DEFINER)를 통해서만 검증


-- =====================================================================
-- 3. Storage 정책 (버킷: workout-attachments)
--    버킷 자체는 대시보드에서 Public으로 수동 생성 필요
-- =====================================================================

-- 인증 사진: 로그인 유저라면 누구나 records/ 경로에 업로드 가능
DROP POLICY IF EXISTS "workout_upload_own" ON storage.objects;
CREATE POLICY "workout_upload_own"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'workout-attachments'
  AND name LIKE 'records/%'
);

-- 프로필 사진: 본인 경로(profiles/{uid}.jpg)에만 업로드 가능
DROP POLICY IF EXISTS "profile_upload_own" ON storage.objects;
CREATE POLICY "profile_upload_own"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'workout-attachments'
  AND name = 'profiles/' || auth.uid()::text || '.jpg'
);

-- 프로필 사진 덮어쓰기(UPDATE)
DROP POLICY IF EXISTS "profile_update_own" ON storage.objects;
CREATE POLICY "profile_update_own"
ON storage.objects FOR UPDATE TO authenticated
USING (
  bucket_id = 'workout-attachments'
  AND name = 'profiles/' || auth.uid()::text || '.jpg'
);

-- 전체 읽기 (버킷이 Public이면 별도 정책 불필요하지만 명시)
DROP POLICY IF EXISTS "public_read_all" ON storage.objects;
CREATE POLICY "public_read_all"
ON storage.objects FOR SELECT TO public
USING (bucket_id = 'workout-attachments');


-- =====================================================================
-- 4. 뷰: leaderboard
--    profiles + workout_records 조인 → 유저별 누적 인증 횟수
--    카운트 기준: workout_name IS NOT NULL (더미 행 제외, 사진 유무 무관)
--    → 30일 후 사진이 삭제돼 image_url이 NULL이 돼도 인증 횟수는 유지됨
-- =====================================================================

CREATE OR REPLACE VIEW public.leaderboard AS
SELECT
  p.id          AS user_id,
  p.nickname    AS nickname,
  p.avatar_id   AS avatar_id,
  p.profile_src AS profile_src,
  count(w.id) FILTER (WHERE w.workout_name IS NOT NULL) AS count
FROM public.profiles p
LEFT JOIN public.workout_records w ON w.user_id = p.id
GROUP BY p.id;


-- =====================================================================
-- 5. RPC 함수 7종
-- =====================================================================

-- ---------------------------------------------------------------------
-- 5-1. room_leaderboard: 방 누적 랭킹 (폴백용)
--      room_leaderboard_month 에러 시 호출됨.
--      멤버십 가드: 해당 방 멤버가 아니면 빈 결과 반환.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.room_leaderboard(p_room_id uuid)
RETURNS TABLE(user_id uuid, nickname text, avatar_id text, profile_src text, count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE uid uuid := auth.uid();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members m
    WHERE m.room_id = p_room_id AND m.user_id = uid
  ) THEN
    RETURN;  -- 멤버가 아니면 빈 결과
  END IF;

  RETURN QUERY
    SELECT p.id, p.nickname, p.avatar_id, p.profile_src,
           count(w.id) FILTER (WHERE w.workout_name IS NOT NULL)
    FROM public.room_members m
    JOIN public.profiles p ON p.id = m.user_id
    LEFT JOIN public.workout_records w ON w.user_id = m.user_id
    WHERE m.room_id = p_room_id
    GROUP BY p.id, p.nickname, p.avatar_id, p.profile_src
    ORDER BY count(w.id) FILTER (WHERE w.workout_name IS NOT NULL) DESC;
END
$function$;

GRANT EXECUTE ON FUNCTION public.room_leaderboard(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5-2. room_leaderboard_month: 월별 랭킹 (랭킹 탭 평소 사용)
--      기간(p_start ~ p_end) 내 인증만 집계.
--      멤버십 가드 포함.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.room_leaderboard_month(
  p_room_id uuid,
  p_start   timestamptz,
  p_end     timestamptz
)
RETURNS TABLE(user_id uuid, nickname text, avatar_id text, profile_src text, count bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE uid uuid := auth.uid();
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.room_members m
    WHERE m.room_id = p_room_id AND m.user_id = uid
  ) THEN
    RETURN;
  END IF;

  RETURN QUERY
    SELECT p.id, p.nickname, p.avatar_id, p.profile_src,
           count(w.id) FILTER (
             WHERE w.workout_name IS NOT NULL
               AND w.created_at >= p_start
               AND w.created_at <  p_end
           )
    FROM public.room_members m
    JOIN public.profiles p ON p.id = m.user_id
    LEFT JOIN public.workout_records w ON w.user_id = m.user_id
    WHERE m.room_id = p_room_id
    GROUP BY p.id, p.nickname, p.avatar_id, p.profile_src
    ORDER BY count(w.id) FILTER (
      WHERE w.workout_name IS NOT NULL
        AND w.created_at >= p_start
        AND w.created_at <  p_end
    ) DESC;
END
$function$;

GRANT EXECUTE ON FUNCTION public.room_leaderboard_month(uuid, timestamptz, timestamptz) TO authenticated;

-- ---------------------------------------------------------------------
-- 5-3. my_rooms: 내가 속한 방 목록 반환
--      반환 필드: id / name / code / is_owner(항상 false, UI에서 createdRoomIds로 판별)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.my_rooms()
RETURNS TABLE(id uuid, name text, code text, is_owner boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE uid uuid := auth.uid();
BEGIN
  RETURN QUERY
    SELECT r.id, r.name, r.code, false::boolean AS is_owner
    FROM public.rooms r
    JOIN public.room_members m ON m.room_id = r.id
    WHERE m.user_id = uid
    ORDER BY m.joined_at ASC;
END
$function$;

GRANT EXECUTE ON FUNCTION public.my_rooms() TO authenticated;

-- ---------------------------------------------------------------------
-- 5-4. create_room: 새 운동방 생성 + 방장 자동 가입
--      6자리 대문자 랜덤 코드 자동 생성 (중복 시 재시도).
--      반환: id / name / code
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_room(p_name text)
RETURNS TABLE(id uuid, name text, code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  uid       uuid := auth.uid();
  new_id    uuid := gen_random_uuid();
  new_code  text;
  attempts  int  := 0;
BEGIN
  -- 중복 없는 6자리 코드 생성 (최대 10회 시도)
  LOOP
    new_code := upper(substring(md5(random()::text) FROM 1 FOR 6));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.rooms r WHERE r.code = new_code);
    attempts := attempts + 1;
    IF attempts >= 10 THEN RAISE EXCEPTION '코드 생성 실패'; END IF;
  END LOOP;

  INSERT INTO public.rooms (id, name, code) VALUES (new_id, p_name, new_code);
  INSERT INTO public.room_members (room_id, user_id) VALUES (new_id, uid);

  RETURN QUERY SELECT new_id, p_name, new_code;
END
$function$;

GRANT EXECUTE ON FUNCTION public.create_room(text) TO authenticated;

-- ---------------------------------------------------------------------
-- 5-5. join_room: 코드로 운동방 참여
--      존재하지 않는 코드면 빈 결과 반환 (에러 아님).
--      이미 멤버면 중복 가입 없이 방 정보만 반환.
--      반환: id / name / code
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_room(p_code text)
RETURNS TABLE(id uuid, name text, code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  uid  uuid := auth.uid();
  room public.rooms%rowtype;
BEGIN
  SELECT * INTO room FROM public.rooms r WHERE upper(r.code) = upper(p_code);
  IF NOT FOUND THEN RETURN; END IF;  -- 없는 코드 → 빈 결과

  INSERT INTO public.room_members (room_id, user_id)
  VALUES (room.id, uid)
  ON CONFLICT DO NOTHING;  -- 이미 멤버 → 무시

  RETURN QUERY SELECT room.id, room.name, room.code;
END
$function$;

GRANT EXECUTE ON FUNCTION public.join_room(text) TO authenticated;

-- ---------------------------------------------------------------------
-- 5-6. leave_room: 운동방 탈퇴
--      본인 멤버십만 삭제 (방 자체·다른 멤버 영향 없음).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.leave_room(p_room_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE uid uuid := auth.uid();
BEGIN
  DELETE FROM public.room_members
  WHERE room_id = p_room_id AND user_id = uid;
END
$function$;

GRANT EXECUTE ON FUNCTION public.leave_room(uuid) TO authenticated;

-- ---------------------------------------------------------------------
-- 5-7. redeem_invite: 앱 진입용 초대코드 검증
--      유효하면 true 반환 + used_count 증가.
--      없거나 비활성이거나 한도 초과면 false 반환.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.redeem_invite(p_code text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE rec public.invite_codes%rowtype;
BEGIN
  SELECT * INTO rec
  FROM public.invite_codes
  WHERE upper(code) = upper(p_code) AND active = true;

  IF NOT FOUND THEN RETURN false; END IF;

  IF rec.max_uses IS NOT NULL AND rec.used_count >= rec.max_uses THEN
    RETURN false;
  END IF;

  UPDATE public.invite_codes SET used_count = used_count + 1 WHERE code = rec.code;
  RETURN true;
END
$function$;

GRANT EXECUTE ON FUNCTION public.redeem_invite(text) TO anon, authenticated;


-- =====================================================================
-- 6. 인증 사진 30일 자동 삭제 (pg_cron)
--    동작:
--      · Storage의 실제 jpg 삭제 → 용량 회수
--      · workout_records.image_url만 NULL로 비움
--      · 행 자체(날짜·종목·시간·메모)는 영구 보존 → 캘린더 유지
--      · 30일 후에도 랭킹 인증 횟수는 유지됨 (leaderboard 뷰 카운트 기준이 사진 무관)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.purge_old_workout_images()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage
AS $$
DECLARE
  rec      RECORD;
  obj_path text;
BEGIN
  FOR rec IN
    SELECT id, image_url
    FROM public.workout_records
    WHERE image_url IS NOT NULL
      AND created_at < now() - INTERVAL '30 days'
  LOOP
    obj_path := split_part(rec.image_url, '/workout-attachments/', 2);
    obj_path := split_part(obj_path, '?', 1);  -- 캐시용 ?v=... 쿼리스트링 제거

    IF obj_path <> '' THEN
      DELETE FROM storage.objects
      WHERE bucket_id = 'workout-attachments' AND name = obj_path;
    END IF;

    UPDATE public.workout_records SET image_url = NULL WHERE id = rec.id;
  END LOOP;
END;
$$;

-- pg_cron 스케줄 등록: 매일 새벽 4시(UTC) = 한국시간 오후 1시
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.unschedule('purge_old_workout_images')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge_old_workout_images');

SELECT cron.schedule(
  'purge_old_workout_images',
  '0 4 * * *',
  $$ SELECT public.purge_old_workout_images(); $$
);


-- =====================================================================
-- 7. 초대코드 초기 데이터
--    아래 코드를 실제 사용할 코드로 변경하세요.
-- =====================================================================

-- 공용 코드 1개 (무제한 사용, 비활성화: active=false로 UPDATE)
INSERT INTO public.invite_codes (code, label, max_uses)
VALUES ('WORKOUT2025', '공용 초대코드', null)
ON CONFLICT (code) DO NOTHING;

-- 1인 1회용 코드 예시 (주석 해제 후 사용)
-- INSERT INTO public.invite_codes (code, label, max_uses) VALUES
--   ('FRIEND-A1B2', '민수에게', 1),
--   ('FRIEND-C3D4', '지영에게', 1)
-- ON CONFLICT (code) DO NOTHING;


-- =====================================================================
-- ※ 자주 쓰는 관리용 쿼리 (참고용, 실행 안 해도 됨)
-- =====================================================================

-- 초대코드 현황 확인
-- SELECT code, label, used_count, max_uses, active FROM public.invite_codes;

-- 초대코드 비활성화
-- UPDATE public.invite_codes SET active = false WHERE code = 'WORKOUT2025';

-- 특정 유저 기록 삭제 (테스트 데이터 정리)
-- DELETE FROM public.workout_records WHERE user_id = '...uuid...';
-- DELETE FROM public.profiles        WHERE id       = '...uuid...';
-- (auth.users는 대시보드 > Auth > Users 에서 삭제)

-- 사진 자동삭제 수동 실행 (테스트)
-- SELECT public.purge_old_workout_images();

-- pg_cron 스케줄 확인
-- SELECT jobname, schedule, command FROM cron.job;
