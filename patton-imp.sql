-- ----------------------------------------------------------------------------------------------- --
-- Skrypt rozszerzający funkcjonalność Teamów o możliwość liczenia wyników turnieju metodą Pattona --
-- Autor: mkl                                                                                      --
-- ----------------------------------------------------------------------------------------------- --
-- Wersja dla turnieju liczonego na IMP->VP                                                        --
-- Ta wersja jest fajna, bo:                                                                       --
--  * działa                                                                                       --
-- Ta wersja jest niefajna, bo:                                                                    --
--  * wymaga wgrania zdegnerowanej tabeli VP (skrypt ją nadpisuje, ale strzyżonego i tak dalej)    --
--    z ustawionym wiecznym remisem (przykładowe tabele - dołączone)                               --
--  * dla rund 3-rozdaniowych wgranie właściwego remisu (4.5:4.5) przez Teamy jest niemożliwe      --
--  * wszystkie zapisy są oznaczane jako "nie do liczenia w meczu",                                --
--    więc każdy mecz jest liczony jako remis (a wynik końcowy ustawiany tylko wyrównaniem)        --
-- ----------------------------------------------------------------------------------------------- --
-- Instrukcja obsługi:                                                                             --
--  * uruchomić w bazie turnieju skrypt co najmniej raz po założeniu turnieju,                     --
--    a przed wpisaniem pierwszego wyrównania "właściwego" (tj. faktycznej kary/wyrównania         --
--    z turnieju)                                                                                  --
--  * uruchomić kazdorazowo celem przeliczenia wyników                                             --
-- Potencjalne problemy:                                                                           --
--  * wyrównania wklepywane z Teamów mogą sprawiać problemy (nie są dostatecznie przetestowane)    --
--  * nie mam zielonego pojęcia, czy i jak powinny obchodzić mnie wyniki niezapisowe w rozdaniach  --
-- Szczególne wymagania dla bazy danych:                                                           --
--  * uprawnienia do tworzenia tabel                                                               --
--  * uprawnienia do tworzenia widoków                                                             --
--  * uprawnienia do tworzenia i uruchamiania wyzwalaczy                                           --
-- Kontrolnie tworzone są tabele/widoki z przedrostkiem patton_, pozwalające w razie czego ogarnąć,--
-- co się dzieje.                                                                                  --
-- ----------------------------------------------------------------------------------------------- --

-- Widok trzymający rozdania, w których są już oba zapisy - tylko te rozdania są dalej brane pod uwagę.
DROP VIEW IF EXISTS patton_boards;
CREATE VIEW patton_boards AS
	SELECT rnd, segment, tabl, board FROM scores WHERE score IS NOT NULL GROUP BY rnd, segment, tabl, board HAVING COUNT(*) = 2;

-- Tabela kompilująca wyniki rozdań, zestawiająca zapisy z obu stołów oraz wyniki części BAMowej Pattona
DROP TABLE IF EXISTS patton_scores;
CREATE TABLE patton_scores (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	board INT, -- z bazy Teamów
	open_score INT, -- score ze scores dla pokoju otwartego
	closed_score INT, -- score ze scores dla pokoju zamkniętego
	h_bam FLOAT, -- punkty BAMowe dla gospodarzy
	v_bam FLOAT -- punkty BAMowe dla gości
);

-- Tabela kompilująca saldo druzyn w meczu
DROP TABLE IF EXISTS patton_sums;
CREATE TABLE patton_sums (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_saldo INT, -- saldo gospodarzy
	v_saldo INT, -- saldo gości
	max_saldo INT, -- większa z 2 powyższych wartości (maksymalne saldo)
	h_points FLOAT, -- punkty za saldo dla gospodarzy
	v_points FLOAT -- punkty za saldo dla gości
);

-- Tabela kompilująca wyrównania (takie, by wynik meczu w VP był równy wynikowi wynikającemu z Pattona)
DROP TABLE IF EXISTS patton_adjustments;
CREATE TABLE patton_adjustments (
	rnd INT, -- z bazy Teamów
	segment INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_total FLOAT, -- wyrównanie dla gospodarzy
	v_total FLOAT -- wyrównanie dla gości
);

-- Tabela zapamiętująca wszelkie "ręczne" zmiany na kolumnach corrv i corrh tabeli matches - więc zwykłe turniejowe wyrównania.
-- Zapamiętujemy celem nałożenia na wyrównania wynikające z wyniku meczu Pattonem.
CREATE TABLE IF NOT EXISTS patton_external_adjustments (
	rnd INT, -- z bazy Teamów
	tabl INT, -- z bazy Teamów
	h_adj FLOAT, -- wyrównanie dla gospodarzy
	v_adj FLOAT, -- wyrównanie dla gości
	PRIMARY KEY (rnd, tabl)
);

SET @h_adj = 0;
SET @v_adj = 0;

DROP TRIGGER IF EXISTS patton_trigger_adjustment;
DELIMITER //
-- Wyzwalacz zapamiętrujący wszelkie "zewnętrzne" zmiany na tabeli matches, w kolumnach corrv i corrh - a więc wyrównania.
CREATE TRIGGER patton_trigger_adjustment BEFORE UPDATE ON matches FOR EACH ROW BEGIN
	IF @patton_disable_trigger <> 1  OR @patton_disable_trigger IS NULL THEN
		IF OLD.corrh <> NEW.corrh THEN
			SET @h_adj = NEW.corrh - OLD.corrh;
		END IF;
		IF OLD.corrv <> NEW.corrv THEN
			SET @v_adj = NEW.corrv - OLD.corrv;
		END IF;
		-- Zapamiętujemy do patton_external_adjustements, wstawiając rekordy, jeśli trzeba.
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

-- Na czas wykonywania skryptu wyłączamy powyższy wyzwalacz (skrypt równiez edytuje matches, w końcu)
SET @patton_disable_trigger = 1;

-- Oznaczamy wszystkie rozdania jako nieliczone do wyniku meczu - każdy mecz powinien wygenerować remis.
UPDATE scores SET mecz = 0;

-- Kompilujemy tabelę wyników rozdań i BAMy dla rozdań.
DELETE FROM patton_scores;
INSERT INTO patton_scores
	SELECT pb.*,
		s1.score AS open_score,
		s2.score AS closed_score,
		-- W Pattonie różnica +/- 10 to jeszcze remis.
		IF(ABS(s1.score - s2.score) > 10, ROUND((s1.score - s2.score) / ABS(s1.score - s2.score)), 0) AS h_bam,
		0 AS v_bam
			FROM patton_boards pb
			JOIN scores s1 ON pb.rnd = s1.rnd AND pb.segment = s1.segment AND pb.tabl = s1.tabl AND pb.board = s1.board AND s1.room = 1
			JOIN scores s2 ON pb.rnd = s2.rnd AND pb.segment = s2.segment AND pb.tabl = s2.tabl AND pb.board = s2.board AND s2.room = 2;
UPDATE patton_scores SET v_bam = -h_bam;

-- Zmienna pomocnicza: liczba rozdań w rundzie.
SET @boards_per_segment = (SELECT boardspersegment FROM admin);
-- Nadpisujemy tabelę VP na wiecznie remisową (6:6 dla 4 rozdań, 4.5:4.5 dla 3 rozdań, 3/2*n:3/2*n dla n rozdań)
UPDATE tabvp SET vpew = 1.5 * @boards_per_segment WHERE dimp = 0;
UPDATE tabvp SET vpns = vpew WHERE dimp = 0;
UPDATE matches SET vph = 1.5 * @boards_per_segment;
UPDATE matches SET vpv = vph;

-- Wypełniamy tabelę salda.
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

-- Roboczo liczymy wynik za saldo względem wyniku 0:0
-- Jeśli róznica salda > 1/3 maksymalnego, to gospodarze zdobywają
-- n/2 punktów przy n rozdaniach
UPDATE patton_sums SET h_points = @boards_per_segment / 2
	WHERE (max_saldo - v_saldo) / max_saldo > 1/3;
-- Jeśli róznica salda > 1/10 maksymalnego, ale < 1/3, to gospodarze zdobywają:
--  * 1 punkt przy 4 rozdaniach
--  * 1/6 * n, zaokrągloną do 0.1 przy n rozdaniach
UPDATE patton_sums SET h_points = IF(@boards_per_segment = 4, 1, ROUND(@boards_per_segment / 6, 1))
	WHERE (max_saldo - v_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Jeśli róznica salda > 1/10 maksymalnego, ale < 1/3, to goście zdobywają:
-- n/2 punktów przy n rozdaniach
UPDATE patton_sums SET h_points = -(@boards_per_segment / 2)
	WHERE (max_saldo - h_saldo) / max_saldo > 1/3;
-- Jeśli róznica salda > 1/10 maksymalnego, ale < 1/3, to goście zdobywają:
--  * 1 punkt przy 4 rozdaniach
--  * 1/6 * n, zaokrągloną do 0.1 przy n rozdaniach
UPDATE patton_sums SET h_points = -IF(@boards_per_segment = 4, 1, ROUND(@boards_per_segment / 6, 1))
	WHERE (max_saldo - h_saldo) / max_saldo BETWEEN 1/10 AND 1/3;
-- Druga drużyna zdobywa dopełnienie do zera.
UPDATE patton_sums SET v_points = -h_points;

-- Kompilujemy wyrównania Pattonowe, jako sumę BAMów i punktów za saldo
DELETE FROM patton_adjustments;
INSERT INTO patton_adjustments
	SELECT patton_sums.rnd, patton_sums.segment, patton_sums.tabl,
		SUM(patton_scores.h_bam) + patton_sums.h_points AS h_total,
		SUM(patton_scores.v_bam) + patton_sums.v_points AS v_total
		FROM patton_sums
		JOIN patton_scores ON patton_sums.rnd = patton_scores.rnd AND patton_sums.segment = patton_scores.segment AND patton_sums.tabl = patton_scores.tabl
		GROUP BY patton_scores.rnd, patton_scores.segment, patton_scores.tabl;

-- Ustawiamy wyrównania w matches, nanosząc na nie zapamiętane "zewnętrzne" wyrównania
UPDATE matches SET
	corrh = COALESCE((SELECT h_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT h_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0),
	corrv = COALESCE((SELECT v_total FROM patton_adjustments WHERE matches.rnd = patton_adjustments.rnd AND matches.tabl = patton_adjustments.tabl AND patton_adjustments.segment = 1), 0)
		+ COALESCE((SELECT v_adj FROM patton_external_adjustments WHERE matches.rnd = patton_external_adjustments.rnd AND matches.tabl = patton_external_adjustments.tabl), 0);

-- Oblokowujemy obsługę wyzwalacza, na wypadek gdybyśmy chcieli coś jeszcze robić na tym samym połączeniu do bazy.
SET @patton_disable_trigger = 0;
