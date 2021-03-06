#include <microscopes/lda/model.hpp>
#include <microscopes/lda/kernels.hpp>
#include <microscopes/lda/random_docs.hpp>
#include <microscopes/common/macros.hpp>
#include <microscopes/models/distributions.hpp>
#include <microscopes/common/random_fwd.hpp>

#include <random>
#include <iostream>

using namespace std;
using namespace distributions;
using namespace microscopes;
using namespace microscopes::common;


static void
sequence_random(double alpha, double beta, double gamma, size_t seed){
    std::cout << alpha << " " << beta << " " << gamma <<std::endl;
    rng_t r(seed);
    std::vector< std::vector<size_t>> docs {{0,1,2,3}, {0,1,4,5}, {0,1,5,6}};
    size_t V = 7;
    lda::model_definition defn(3, V);
    lda::state state(defn, alpha, beta, gamma, 2, docs, r);
    for(unsigned i = 0; i < 10; ++i){
        microscopes::kernels::lda_crp_gibbs(state, r);
    }
    std::cout << "perplexity: " << state.perplexity() << std::endl;
}

static void
test_random_sequences(){
    sequence_random(0.2, 0.01, 0.5, 0);
    sequence_random(0.2, 0.01, 0.01, 6);
    sequence_random(0.2, 0.01, 0.5, 2);
    sequence_random(0.01, 0.001, 0.05, 13);
}


static void
test_explicit_initializtion(){
    double alpha = 0.2;
    double beta = 0.01;
    double gamma = 0.5;
    std::vector< std::vector<size_t>> docs {{0,1,2,3}, {0,1,4}, {0,1,5,6}};
    size_t V = 7;
    lda::model_definition defn(3, V);
    std::vector<std::vector<size_t>> table_assignments = {{1, 2, 1, 2}, {1, 1, 1}, {3, 3, 3, 1}};
    std::vector<std::vector<size_t>> dish_assignments = {{0, 1, 2}, {0, 3}, {0, 1, 2, 1}};
    lda::state state(defn, alpha, beta, gamma,
                     dish_assignments, table_assignments, docs);
    MICROSCOPES_CHECK(table_assignments.size() == state.table_assignments().size(), "table_assignments is wrong length");
    MICROSCOPES_CHECK(dish_assignments.size() == state.dish_assignments().size(), "table_assignments is wrong length");
}

int main(void){
    test_random_sequences();
    std::cout << "test_random_sequences passed" << std::endl;
    test_explicit_initializtion();
    std::cout << "test_explicit_initializtion passed" << std::endl;
    return 0;
}