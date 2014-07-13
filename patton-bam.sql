-- ----------------------------------------------------------------------------------------------- --
-- Skrypt rozszerzaj¹cy funkcjonalnoœæ Teamów o mo¿liwoœæ liczenia wyników turnieju metod¹ Pattona --
-- Autor: mkl                                                                                      --
-- ----------------------------------------------------------------------------------------------- --
-- Wersja dla turnieju liczonego BAMami                                                            --
-- Ta wersja jest fajna, bo:                                                                       --
--  * dzia³a                                                                                       --
--  * nie generuje ca³ego mnóstwa pustych protoko³ów - czêœæ BAMowa liczy siê normalnie BAMami     --
-- Ta wersja jest niefajna, bo:                                                                    --
--  * BAMy w Teamach licz¹ ró¿nicê +/- 10 jako nieremis, wiêc w protokole jest 2:0/0:2,            --
--    wiêc jest "po cichu" wyrównywane w jednym worze raze z wyrównaniami za saldo,                --
--    wiêc generuje ca³e mnóstwo pytañ "a panie sêdzio, czemu tu jest 2:0, jak mia³o byæ 1:1"      --
-- ----------------------------------------------------------------------------------------------- --
-- Instrukcja obs³ugi:                                                                             --
--  * uruchomiæ w bazie turnieju skrypt co najmniej raz po za³o¿eniu turnieju,                     --
--    a przed wpisaniem pierwszego wyrównania "w³aœciwego" (tj. faktycznej kary/wyrównania         --
--    z turnieju)                                                                                  --
--  * uruchomiæ kazdorazowo celem przeliczenia wyników                                             --
-- Potencjalne problemy:                                                                           --
--  * wyrównania wklepywane z Teamów mog¹ sprawiaæ problemy (nie s¹ dostatecznie przetestowane)    --
--  * nie mam zielonego pojêcia, czy i jak powinny obchodziæ mnie wyniki niezapisowe w rozdaniach  --
-- Szczególne wymagania dla bazy danych:                                                           --
--  * uprawnienia do tworzenia tabel                                                               --
--  * uprawnienia do tworzenia widoków                                                             --
--  * uprawnienia do tworzenia i uruchamiania wyzwalaczy                                           --
-- Kontrolnie tworzone s¹ tabele/widoki z przedrostkiem patton_, pozwalaj¹ce w razie czego ogarn¹æ,--
-- co siê dzieje.                                                                                  --
-- ----------------------------------------------------------------------------------------------- --

-- Widok trzymaj¹cy rozdania, w których s¹ ju¿ oba zapisy - tylko te rozdania s¹ dalej brane pod uwagê.
DROP VIEW IF EXISTS patton_boards;
CREATE VIEW patton_boards AS
	SELECT rnd, segment, tabl, board FROM scores WHERE score IS NOT NULL GROUP BY rnd, segment, tabl, board HAVING COUNT(*) = 2;

-- Tabela kompiluj¹ca wyniki rozdañ, zestawiaj¹ca zapisy z obu sto³ów oraz wyrównania wzglêdem BAMów (dla rozdañ, gdzie pada remis +/- 10)
DROP TABLE IF EXISTS patton_scores;
CREATE TABLE patton_scores (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	board INT, -- z bazy Teamów
	open_score INT, -- score ze scores dla pokoju otwartego
	closed_score INT, -- score ze scores dla pokoju zamkniêtego
	h_bam FLOAT, -- punkty BAMowe dla gospodarzy
	v_bam FLOAT -- punkty BAMowe dla goœci
);
	
-- Tabela kompiluj¹ca saldo druzyn w meczu
DROP TABLE IF EXISTS patton_sums;
CREATE TABLE patton_sums (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_saldo INT, -- saldo gospodarzy
	v_saldo INT, -- saldo goœci
	max_saldo INT, -- wiêksza z 2 powy¿szych wartoœci (maksymalne saldo)
	h_points FLOAT, -- punkty za saldo dla gospodarzy
	v_points FLOAT -- punkty za saldo dla goœci
);

-- Tabela kompiluj¹ca wyrównania (takie, by wynik meczu w VP by³ równy wynikowi wynikaj¹cemu z Pattona)
DROP TABLE IF EXISTS patton_adjustments;
CREATE TABLE patton_adjustments (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_total FLOAT, -- wyrównanie dla gospodarzy
	v_total FLOAT -- wyrównanie dla goœci
);

-- Tabela zapamiêtuj¹ca wszelkie "rêczne" zmiany na kolumnach corrv i corrh tabeli matches - wiêc zwyk³e turniejowe wyrównania.
-- Zapamiêtujemy celem na³o¿enia na wyrównania wynikaj¹ce z wyniku meczu Pattonem.
CREATE TABLE IF NOT EXISTS patton_external_adjustments (
	rnd INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_adj FLOAT, -- wyrównanie dla gospodarzy
	v_adj FLOAT, -- wyrównanie dla goœci
	PRIMARY KEY (rnd, tabl)
);

SET @h_adj = 0;
SET @v_adj = 0;

DROP TRIGGER IF EXISTS patton_trigger_adjustment;
DELIMITER //
-- Wyzwalacz zapamiêtruj¹cy wszelkie "zewnêtrzne" zmiany na tabeli matches, w kolumnach corrv i corrh - a wiêc wyrównania.
CREATE TRIGGER patton_trigger_adjustment BEFORE UPDATE ON matches FOR EACH ROW BEGIN
	IF @patton_disable_trigger <> 1 OR @patton_disable_trigger IS NULL THEN
		SET @h_adj = NEW.corrh - COALESCE(OLD.corrh, 0);
		SET @v_adj = NEW.corrv - COALESCE(OLD.corrv, 0);
		-- Zapamiêtujemy do patton_external_adjustements, wstawiaj¹c rekordy, jeœli trzeba.
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

-- Na czas wykonywania skryptu wy³¹czamy powy¿szy wyzwalacz (skrypt równiez edytuje matches, w koñcu)
SET @patton_disable_trigger = 1;

-- Kompilujemy tabelê wyników rozdañ i wyrówniania dla czêœæi BAM z rozdañ.
DELETE FROM patton_scores;
INSERT INTO patton_scores
	SELECT pb.*,
		s1.score AS open_score,
		s2.score AS closed_score,
		-- Rodzania z ró¿nic¹ +/- 10 wymagaj¹ wyrównania -1 na niekorzyœæ strony, która wziê³a +10
		IF(ABS(s1.score - s2.score) = 10, IF(s1.score > s2.score, -1, 1), 0) AS h_bam,
		0 AS v_bam
			FROM patton_boards pb
			JOIN scores s1 ON pb.rnd = s1.rnd AND pb.segment = s1.segment AND pb.tabl = s1.tabl AND pb.board = s1.board AND s1.room = 1
			JOIN scores s2 ON pb.rnd = s2.rnd AND pb.segment = s2.segment AND pb.tabl = s2.tabl AND pb.board = s2.board AND s2.room = 2;
UPDATE patton_scores SET v_bam = -h_bam;

-- Zmienna pomocnicza do wyliczenia punktów za saldo w zale¿noœci od liczby rozdañ w rundzie.
SET @boards_per_segment = IF ((SELECT boardspersegment FROM admin) = 4, 1, 0.5); -- Dla 4 rozdañ: = 1.0, dla 3 rozdañ: = 0.5

-- Wype³niamy tabelê salda.
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

-- Roboczo liczymy wynik za saldo wzglêdem wyniku 0:0
-- Jeœli róznica salda > 1/3 maksymalnego, to gospodarze zdobywaj¹:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = 2 * @boards_per_segment
	WHERE (max_saldo - v_saldo) / max_saldo > 1/3;
-- Jeœli róznica salda > 1/10 maksymalnego, ale < 1/3, to gospodarze zdobywaj¹:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = 1 * @boards_per_segment
	WHERE (max_saldo - v_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Jeœli róznica salda > 1/10 maksymalnego, ale < 1/3, to goœcie zdobywaj¹:
--  * 2 punkty przy 4 rozdaniach
--  * 1 punkt przy 3 rozdaniach
UPDATE patton_sums SET h_points = -2 * @boards_per_segment
	WHERE (max_saldo - h_saldo) / max_saldo > 1/3;
-- Jeœli róznica salda > 1/10 maksymalnego, ale < 1/3, to goœcie zdobywaj¹:
--  * 1 punkt przy 4 rozdaniach
--  * 0.5 punktu przy 3 rozdaniach
UPDATE patton_sums SET h_points = -1 * @boards_per_segment
	WHERE (max_saldo - h_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Druga dru¿yna zdobywa dope³nienie do zera.
UPDATE patton_sums SET v_points = -h_points;
-- Podnosimy wynik za saldo z punktu odniesienia 0:0 do w³aœciwego remisu, zale¿nego od liczby rozdañ (2:2 dla 4, 1:1 dla 3)
UPDATE patton_sums SET v_points = v_points + 2 * @boards_per_segment;
UPDATE patton_sums SET h_points = h_points + 2 * @boards_per_segment;

-- Kompilujemy wyrównania Pattonowe, jako sumê wyrównañ z BAMów i punktów za saldo
DELETE FROM patton_adjustments;
INSERT INTO patton_adjustments
	SELECT patton_sums.rnd, patton_sums.segment, patton_sums.tabl,
		SUM(patton_scores.h_bam) + patton_sums.h_points AS h_total,
		SUM(patton_scores.v_bam) + patton_sums.v_points AS v_total
		FROM patton_sums
		JOIN patton_scores ON patton_sums.rnd = patton_scores.rnd AND patton_sums.segment = patton_scores.segment AND patton_sums.tabl = patton_scores.tabl
		GROUP BY patton_scores.rnd, patton_scores.segment, patton_scores.tabl;

-- Ustawiamy wyrównania w matches, nanosz¹c na nie zapamiêtane "zewnêtrzne" wyrównania
UPDATE matches SET
	corrh = COALESCE((SELECT h_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT h_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0),
	corrv = COALESCE((SELECT v_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT v_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0);

-- Oblokowujemy obs³ugê wyzwalacza, na wypadek gdybyœmy chcieli coœ jeszcze robiæ na tym samym po³¹czeniu do bazy.
SET @patton_disable_trigger = 0;
