-- ----------------------------------------------------------------------------------------------- --
-- Skrypt rozszerzaj�cy funkcjonalno�� Team�w o mo�liwo�� liczenia wynik�w turnieju metod� Pattona --
-- Autor: mkl                                                                                      --
-- ----------------------------------------------------------------------------------------------- --
-- Wersja dla turnieju liczonego BAMami                                                            --
-- Ta wersja jest fajna, bo:                                                                       --
--  * dzia�a                                                                                       --
--  * nie generuje ca�ego mn�stwa pustych protoko��w - cz�� BAMowa liczy si� normalnie BAMami     --
-- Ta wersja jest niefajna, bo:                                                                    --
--  * BAMy w Teamach licz� r�nic� +/- 10 jako nieremis, wi�c w protokole jest 2:0/0:2,            --
--    wi�c jest "po cichu" wyr�wnywane w jednym worze raze z wyr�wnaniami za saldo,                --
--    wi�c generuje ca�e mn�stwo pyta� "a panie s�dzio, czemu tu jest 2:0, jak mia�o by� 1:1"      --
-- ----------------------------------------------------------------------------------------------- --
-- Instrukcja obs�ugi:                                                                             --
--  * uruchomi� w bazie turnieju skrypt co najmniej raz po za�o�eniu turnieju,                     --
--    a przed wpisaniem pierwszego wyr�wnania "w�a�ciwego" (tj. faktycznej kary/wyr�wnania         --
--    z turnieju)                                                                                  --
--  * uruchomi� kazdorazowo celem przeliczenia wynik�w                                             --
-- Potencjalne problemy:                                                                           --
--  * wyr�wnania wklepywane z Team�w mog� sprawia� problemy (nie s� dostatecznie przetestowane)    --
--  * nie mam zielonego poj�cia, czy i jak powinny obchodzi� mnie wyniki niezapisowe w rozdaniach  --
-- Szczeg�lne wymagania dla bazy danych:                                                           --
--  * uprawnienia do tworzenia tabel                                                               --
--  * uprawnienia do tworzenia widok�w                                                             --
--  * uprawnienia do tworzenia i uruchamiania wyzwalaczy                                           --
-- Kontrolnie tworzone s� tabele/widoki z przedrostkiem patton_, pozwalaj�ce w razie czego ogarn��,--
-- co si� dzieje.                                                                                  --
-- ----------------------------------------------------------------------------------------------- --

-- Widok trzymaj�cy rozdania, w kt�rych s� ju� oba zapisy - tylko te rozdania s� dalej brane pod uwag�.
DROP VIEW IF EXISTS patton_boards;
CREATE VIEW patton_boards AS
	SELECT rnd, segment, tabl, board FROM scores WHERE score IS NOT NULL GROUP BY rnd, segment, tabl, board HAVING COUNT(*) = 2;

-- Tabela kompiluj�ca wyniki rozda�, zestawiaj�ca zapisy z obu sto��w oraz wyr�wnania wzgl�dem BAM�w (dla rozda�, gdzie pada remis +/- 10)
DROP TABLE IF EXISTS patton_scores;
CREATE TABLE patton_scores (
	rnd INT, -- z bazy Team�w
	segment INT, -- z bazy Team�w
	tabl INT, -- z bazy Team�w
	board INT, -- z bazy Team�w
	open_score INT, -- score ze scores dla pokoju otwartego
	closed_score INT, -- score ze scores dla pokoju zamkni�tego
	h_bam FLOAT, -- punkty BAMowe dla gospodarzy
	v_bam FLOAT -- punkty BAMowe dla go�ci
);
	
-- Tabela kompiluj�ca saldo druzyn w meczu
DROP TABLE IF EXISTS patton_sums;
CREATE TABLE patton_sums (
	rnd INT, -- z bazy Team�w
	segment INT, -- z bazy Team�w
	tabl INT, -- z bazy Team�w
	h_saldo INT, -- saldo gospodarzy
	v_saldo INT, -- saldo go�ci
	max_saldo INT, -- wi�ksza z 2 powy�szych warto�ci (maksymalne saldo)
	h_points FLOAT, -- punkty za saldo dla gospodarzy
	v_points FLOAT -- punkty za saldo dla go�ci
);

-- Tabela kompiluj�ca wyr�wnania (takie, by wynik meczu w VP by� r�wny wynikowi wynikaj�cemu z Pattona)
DROP TABLE IF EXISTS patton_adjustments;
CREATE TABLE patton_adjustments (
	rnd INT, -- z bazy Team�w
	segment INT, -- z bazy Team�w
	tabl INT, -- z bazy Team�w
	h_total FLOAT, -- wyr�wnanie dla gospodarzy
	v_total FLOAT -- wyr�wnanie dla go�ci
);

-- Tabela zapami�tuj�ca wszelkie "r�czne" zmiany na kolumnach corrv i corrh tabeli matches - wi�c zwyk�e turniejowe wyr�wnania.
-- Zapami�tujemy celem na�o�enia na wyr�wnania wynikaj�ce z wyniku meczu Pattonem.
CREATE TABLE IF NOT EXISTS patton_external_adjustments (
	rnd INT, -- z bazy Team�w
	tabl INT, -- z bazy Team�w
	h_adj FLOAT, -- wyr�wnanie dla gospodarzy
	v_adj FLOAT, -- wyr�wnanie dla go�ci
	PRIMARY KEY (rnd, tabl)
);

SET @h_adj = 0;
SET @v_adj = 0;

DROP TRIGGER IF EXISTS patton_trigger_adjustment;
DELIMITER //
-- Wyzwalacz zapami�truj�cy wszelkie "zewn�trzne" zmiany na tabeli matches, w kolumnach corrv i corrh - a wi�c wyr�wnania.
CREATE TRIGGER patton_trigger_adjustment BEFORE UPDATE ON matches FOR EACH ROW BEGIN
	IF @patton_disable_trigger <> 1 OR @patton_disable_trigger IS NULL THEN
		SET @h_adj = NEW.corrh - COALESCE(OLD.corrh, 0);
		SET @v_adj = NEW.corrv - COALESCE(OLD.corrv, 0);
		-- Zapami�tujemy do patton_external_adjustements, wstawiaj�c rekordy, je�li trzeba.
		IF (SELECT COUNT(*) FROM patton_external_adjustments WHERE rnd = NEW.rnd AND tabl = NEW.tabl) THEN
			UPDATE patton_external_adjustments
				SET h_adj = h_adj + @h_adj, v_adj = v_adj + @v_adj
				WHERE rnd = NEW.rnd AND tabl = NEW.tabl;
		ELSE
			INSERT INTO patton_external_adjustments(rnd, tabl, h_adj, v_adj)
				VALUES(NEW.rnd, NEW.tabl, @h_adj, @v_adj);
		END IF;
		SET @h_adj = 0;
		SET @v_adj = 0;
	END IF;
END //
DELIMITER ;

-- Na czas wykonywania skryptu wy��czamy powy�szy wyzwalacz (skrypt r�wniez edytuje matches, w ko�cu)
SET @patton_disable_trigger = 1;

-- Kompilujemy tabel� wynik�w rozda� i wyr�wniania dla cz��i BAM z rozda�.
DELETE FROM patton_scores;
INSERT INTO patton_scores
	SELECT pb.*,
		s1.score AS open_score,
		s2.score AS closed_score,
		-- Rodzania z r�nic� +/- 10 wymagaj� wyr�wnania -1 na niekorzy�� strony, kt�ra wzi�a +10
		IF(ABS(s1.score - s2.score) = 10, IF(s1.score > s2.score, -1, 1), 0) AS h_bam,
		0 AS v_bam
			FROM patton_boards pb
			JOIN scores s1 ON pb.rnd = s1.rnd AND pb.segment = s1.segment AND pb.tabl = s1.tabl AND pb.board = s1.board AND s1.room = 1
			JOIN scores s2 ON pb.rnd = s2.rnd AND pb.segment = s2.segment AND pb.tabl = s2.tabl AND pb.board = s2.board AND s2.room = 2;
UPDATE patton_scores SET v_bam = -h_bam;

-- Zmienna pomocnicza do wyliczenia punkt�w za saldo w zale�no�ci od liczby rozda� w rundzie.
SET @boards_per_segment = IF ((SELECT boardspersegment FROM admin) = 4, 1, 0.5); -- Dla 4 rozda�: = 1.0, dla 3 rozda�: = 0.5

-- Wype�niamy tabel� salda.
DELETE FROM patton_sums;
INSERT INTO patton_sums
	SELECT
		patton_scores.rnd, patton_scores.segment, patton_scores.tabl,
		SUM(IF(open_score > 0, open_score, 0)) + SUM(IF(closed_score < 0, -closed_score, 0)) AS h_saldo,
		SUM(IF(open_score < 0, -open_score, 0)) + SUM(IF(closed_score > 0, closed_score, 0)) AS v_saldo,
		0 AS max_saldo,
		0.0 AS h_points,
		0.0 AS v_points
		FROM patton_scores
		GROUP BY rnd, segment, tabl;

-- Wybieramy maksymalne saldo
UPDATE patton_sums SET max_saldo = IF (h_saldo > v_saldo, h_saldo, v_saldo);

-- Roboczo liczymy wynik za saldo wzgl�dem wyniku 0:0
-- Je�li r�znica salda > 1/3 maksymalnego, to gospodarze zdobywaj�:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = 2 * @boards_per_segment
	WHERE (max_saldo - v_saldo) / max_saldo > 1/3;
-- Je�li r�znica salda > 1/10 maksymalnego, ale < 1/3, to gospodarze zdobywaj�:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = 1 * @boards_per_segment
	WHERE (max_saldo - v_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Je�li r�znica salda > 1/10 maksymalnego, ale < 1/3, to go�cie zdobywaj�:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = -2 * @boards_per_segment
	WHERE (max_saldo - h_saldo) / max_saldo > 1/3;
-- Je�li r�znica salda > 1/10 maksymalnego, ale < 1/3, to go�cie zdobywaj�:
--  * 1 punkt przy 4 rozdaniach
--  * 0.5 punktu przy 3 rozdaniach
UPDATE patton_sums SET h_points = -1 * @boards_per_segment
	WHERE (max_saldo - h_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Druga dru�yna zdobywa dope�nienie do zera.
UPDATE patton_sums SET v_points = -h_points;
-- Podnosimy wynik za saldo z punktu odniesienia 0:0 do w�a�ciwego remisu, zale�nego od liczby rozda� (2:2 dla 4, 1:1 dla 3)
UPDATE patton_sums SET v_points = v_points + 2 * @boards_per_segment;
UPDATE patton_sums SET h_points = h_points + 2 * @boards_per_segment;

-- Kompilujemy wyr�wnania Pattonowe, jako sum� wyr�wna� z BAM�w i punkt�w za saldo
DELETE FROM patton_adjustments;
INSERT INTO patton_adjustments
	SELECT patton_sums.rnd, patton_sums.segment, patton_sums.tabl,
		SUM(patton_scores.h_bam) + patton_sums.h_points AS h_total,
		SUM(patton_scores.v_bam) + patton_sums.v_points AS v_total
		FROM patton_sums
		JOIN patton_scores ON patton_sums.rnd = patton_scores.rnd AND patton_sums.segment = patton_scores.segment AND patton_sums.tabl = patton_scores.tabl
		GROUP BY patton_scores.rnd, patton_scores.segment, patton_scores.tabl;

-- Ustawiamy wyr�wnania w matches, nanosz�c na nie zapami�tane "zewn�trzne" wyr�wnania
UPDATE matches SET
	corrh = COALESCE((SELECT h_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT h_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0),
	corrv = COALESCE((SELECT v_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT v_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0);

-- Oblokowujemy obs�ug� wyzwalacza, na wypadek gdyby�my chcieli co� jeszcze robi� na tym samym po��czeniu do bazy.
SET @patton_disable_trigger = 0;
