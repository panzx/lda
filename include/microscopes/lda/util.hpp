#pragma once

#include <math.h>
#include <vector>
#include <set>

namespace lda_util {

    inline bool
    valid_probability_vector(const std::vector<float> &p){
        float sum = 0;
        for(auto x: p){
            if(std::isfinite(x) == false) return false;
            if(x < 0) return false;
            sum+=x;
        }
        return (std::abs(1 - sum) < 0.01);
    }

    template<typename T>
    std::set<T>
    unique_members(std::vector<std::vector<T>> nested_list){
        std::set<T> unique_values;
        for(std::vector<T> list: nested_list){
            for(T val: list){
                unique_values.insert(val);
            }
        }
        return unique_values;
    }

    template<typename T>
    T
    max_element(std::vector<std::vector<T>> nested_list){
        std::set<T> unique_values;
        for(std::vector<T> list: nested_list){
            for(T val: list){
                unique_values.insert(val);
            }
        }
        return *std::max_element(unique_values.begin(), unique_values.end());
    }

    template<typename T> void
    removeFirst(std::vector<T> &v, T element){
        auto it = std::find(v.begin(),v.end(), element);
        if (it != v.end()) {
          v.erase(it);
        }
    }

    // http://stackoverflow.com/a/1267878/982745
    template< class T >
    std::vector<T>
    selectByIndex(const std::vector<T> &v, const std::vector<size_t> &index )  {
        std::vector<T> new_v;
        new_v.reserve(index.size());
        for(size_t i: index){
            new_v.push_back(v[i]);
        }

        return new_v;
    }


    template<class T>
    void
    normalize(std::vector<T> &v){
        Eigen::Map<Eigen::Matrix<T, Eigen::Dynamic, 1>> vec(v.data(), v.size());
        vec /= vec.sum();
    }

    template<class T, class J>
    class defaultdict{
        J default_value;
        std::map<T, J> map;
    public:
        defaultdict(J val){
            default_value = val;
            map = std::map<T, J>();
        }

        J get(T t) const {
            if(map.count(t) > 0){
                return map.at(t);
            }
            else{
                return default_value;
            }
        }

        void
        set(T t, J j){
            map[t] = j;
        }

        void
        incr(T t, J by){
            if(map.count(t) > 0){
                map[t] += by;
            }
            else{
                map[t] = by + default_value;
            }
        }

        void
        decr(T t, J by){
            if(map.count(t) > 0){
                map[t] -= by;
            }
            else{
                map[t] = default_value - by;
            }
        }

        bool
        contains(T t){
            return map.count(t) > 0;
        }
    };
}