-- ----------------------------------------------------------------------------------------------- --
-- Skrypt rozszerzaj¹cy funkcjonalnoœæ Teamów o mo¿liwoœæ liczenia wyników turnieju metod¹ Pattona --
-- Autor: mkl                                                                                      --
-- ----------------------------------------------------------------------------------------------- --
-- Wersja dla turnieju liczonego na IMP->VP                                                        --
-- Ta wersja jest fajna, bo:                                                                       --
--  * dzia³a                                                                                       --
-- Ta wersja jest niefajna, bo:                                                                    --
--  * wymaga wgrania zdegnerowanej tabeli VP (skrypt j¹ nadpisuje, ale strzy¿onego i tak dalej)    --
--    z ustawionym wiecznym remisem (przyk³adowe tabele - do³¹czone)                               --
--  * dla rund 3-rozdaniowych wgranie w³aœciwego remisu (4.5:4.5) przez Teamy jest niemo¿liwe      --
--  * wszystkie zapisy s¹ oznaczane jako "nie do liczenia w meczu",                                --
--    wiêc ka¿dy mecz jest liczony jako remis (a wynik koñcowy ustawiany tylko wyrównaniem)        --
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

-- Tabela kompiluj¹ca wyniki rozdañ, zestawiaj¹ca zapisy z obu sto³ów oraz wyniki czêœci BAMowej Pattona
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
	IF @patton_disable_trigger <> 1  OR @patton_disable_trigger IS NULL THEN
		IF OLD.corrh <> NEW.corrh THEN
			SET @h_adj = NEW.corrh - OLD.corrh;
		END IF;
		IF OLD.corrv <> NEW.corrv THEN
			SET @v_adj = NEW.corrv - OLD.corrv;
		END IF;
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

-- Oznaczamy wszystkie rozdania jako nieliczone do wyniku meczu - ka¿dy mecz powinien wygenerowaæ remis.
UPDATE scores SET mecz = 0;

-- Kompilujemy tabelê wyników rozdañ i BAMy dla rozdañ.
DELETE FROM patton_scores;
INSERT INTO patton_scores
	SELECT pb.*,
		s1.score AS open_score,
		s2.score AS closed_score,
		-- W Pattonie ró¿nica +/- 10 to jeszcze remis.
		IF(ABS(s1.score - s2.score) > 10, ROUND((s1.score - s2.score) / ABS(s1.score - s2.score)), 0) AS h_bam,
		0 AS v_bam
			FROM patton_boards pb
			JOIN scores s1 ON pb.rnd = s1.rnd AND pb.segment = s1.segment AND pb.tabl = s1.tabl AND pb.board = s1.board AND s1.room = 1
			JOIN scores s2 ON pb.rnd = s2.rnd AND pb.segment = s2.segment AND pb.tabl = s2.tabl AND pb.board = s2.board AND s2.room = 2;
UPDATE patton_scores SET v_bam = -h_bam;

-- Zmienna pomocnicza do wyliczenia punktów za saldo w zale¿noœci od liczby rozdañ w rundzie.
SET @boards_per_segment = IF ((SELECT boardspersegment FROM admin) = 4, 1, 0.5); -- Dla 4 rozdañ: = 1.0, dla 3 rozdañ: = 0.5
-- Nadpisujemy tabelê VP na wiecznie remisow¹ (6:6 dla 4 rozdañ, 4.5:4.5 dla 3 rozdañ)
UPDATE tabvp SET vpew = 3 + 3 * @boards_per_segment WHERE dimp = 0;
UPDATE tabvp SET vpns = vpew WHERE dimp = 0;
UPDATE matches SET vph = 3 + 3 * @boards_per_segment;
UPDATE matches SET vpv = vph;

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

-- Kompilujemy wyrównania Pattonowe, jako sumê BAMów i punktów za saldo
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
